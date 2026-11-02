import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {database,transaction,submitWithinTransaction,claim,settle} from '../api/_lib/ledger';
import {validateConditionPlan, type ConditionPlan} from '../api/_lib/condition-workflow';
import {submitConditionWorkflow,prepareConditionStep,finishConditionStep} from '../api/_lib/condition-workflow-store';

test('condition retry identities must be explicit UUIDs', () => {
  const contract={instructions:'synthetic',response_format:{type:'json_schema',json_schema:{name:'fixture',strict:true,schema:{type:'object',properties:{},additionalProperties:false}}}};
  const plan: ConditionPlan = {version:1, preserved:{groups:[],unassigned:[]}, batches:[],contextEntries:[],
    mapping:contract, verification:contract};
  assert.equal(validateConditionPlan({...plan,retryAttempt:randomUUID()}).version,1);
  for (const retryAttempt of ['',true,'automatic','private text']) {
    assert.throws(()=>validateConditionPlan({...plan,retryAttempt}));
  }
});

test('explicit recovery replaces one uncertain call, retains charges, deduplicates retries and reuses completed work', {
  skip: !process.env.AI_RECOVERY_TEST_DATABASE_URL,
}, async () => {
  const url = new URL(process.env.AI_RECOVERY_TEST_DATABASE_URL!);
  assert.ok(['localhost','127.0.0.1'].includes(url.hostname) && url.pathname.startsWith('/cc_test_'));
  process.env.DATABASE_URL=url.href;
  process.env.AI_BUDGET_ID='evaluation-v1';
  process.env.AI_DEDUPE_SECRET='synthetic-recovery-only';
  const db=database();
  const payload={stage:'condition-synthesis',instructions:'Synthetic fixture',input:'Synthetic record',response_format:{type:'json_object'}};
  const submit=(attempt?:string,input=payload.input)=>transaction(client=>submitWithinTransaction(
    client,'synthetic-owner',{...payload,input},'evaluation-v1','gpt-4o-mini','low','synthetic-parent',attempt));
  try {
    assert.equal((await db.query("SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema='public'")).rows[0].n,0);
    for (const file of ['001_ai_ledger.sql','002_condition_workflows.sql','003_workflow_cost_attribution.sql',
      '004_workload_types.sql','005_workflow_model.sql','006_workflow_reasoning.sql','007_condition_uploads.sql']) {
      await db.query(await readFile(`migrations/${file}`,'utf8'));
    }
    const original=await submit();
    assert.ok(await claim(original.id));
    await settle(original.id,'uncertain');
    const reserved=BigInt((await db.query("SELECT reserved_nusd FROM ai_budgets WHERE id='evaluation-v1'")).rows[0].reserved_nusd);
    assert.equal((await submit()).id,original.id,'Ordinary Retry cannot repeat an unknown paid call');
    const attempt=randomUUID();
    const replacements=await Promise.all(Array.from({length:12},()=>submit(attempt)));
    assert.equal(new Set(replacements.map(job=>job.id)).size,1,'Concurrent resumes reserve only once');
    const replacement=replacements[0];
    assert.notEqual(replacement.id,original.id);
    assert.equal(BigInt((await db.query("SELECT reserved_nusd FROM ai_budgets WHERE id='evaluation-v1'")).rows[0].reserved_nusd),2n*reserved);
    assert.ok(await claim(replacement.id));
    await settle(replacement.id,'uncertain');
    assert.equal((await submit(attempt)).id,replacement.id,'A second uncertain result cannot silently create a third request');
    assert.equal((await submit()).id,original.id,'The original outcome is never erased');
    assert.notEqual((await submit(randomUUID())).id,replacement.id,'A separate explicit approval may start a separate attempt');
    const completed=await submit(undefined,'Already completed synthetic record');
    assert.ok(await claim(completed.id));
    await settle(completed.id,'completed',{input_tokens:10,output_tokens:2},'Synthetic completed result');
    assert.equal((await submit(randomUUID(),'Already completed synthetic record')).id,completed.id);
    assert.equal((await db.query('SELECT state FROM ai_jobs WHERE id=$1',[original.id])).rows[0].state,'uncertain');
    await assert.rejects(()=>submit('not-a-UUID'),/invalid_request/);

    // Exercise the actual parent-to-child path, including a resumed upload.
    const contract={instructions:'Synthetic workflow contract',response_format:{type:'json_schema',json_schema:{name:'fixture',strict:true,schema:{type:'object',properties:{},additionalProperties:false}}}};
    const plan:ConditionPlan={version:1,preserved:{groups:[],unassigned:[]},contextEntries:[],
      batches:[[{id:randomUUID(),title:'Synthetic concern',excerpt:'Synthetic source'}]],mapping:contract,verification:contract};
    const parent=await submitConditionWorkflow('synthetic-parent-owner',plan);
    const stoppedChild=await prepareConditionStep(parent.id);
    assert.ok(await claim(stoppedChild!));await settle(stoppedChild!,'uncertain');
    assert.equal((await finishConditionStep(parent.id,stoppedChild!))?.state,'uncertain');
    assert.equal((await submitConditionWorkflow('synthetic-parent-owner',plan)).id,parent.id);
    const explicitPlan={...plan,retryAttempt:randomUUID()};
    const newParent=await submitConditionWorkflow('synthetic-parent-owner',explicitPlan);
    assert.notEqual(newParent.id,parent.id);
    assert.equal((await submitConditionWorkflow('synthetic-parent-owner',explicitPlan)).id,newParent.id);
    const newChild=await prepareConditionStep(newParent.id);
    assert.notEqual(newChild,stoppedChild);
    assert.equal(await prepareConditionStep(newParent.id),newChild);
    assert.ok(await claim(newChild!));await settle(newChild!,'uncertain');
    assert.equal((await finishConditionStep(newParent.id,newChild!))?.state,'uncertain');
    assert.equal(await prepareConditionStep(newParent.id),null,'A new uncertain outcome stops this approved attempt');
  } finally {await db.end();}
});
