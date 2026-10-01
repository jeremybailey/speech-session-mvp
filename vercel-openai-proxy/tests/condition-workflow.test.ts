import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { ConditionPlan,validateConditionPlan,initialConditionState,nextConditionRequest,acceptConditionResponse } from '../api/_lib/condition-workflow';
import { submitConditionWorkflow,prepareConditionStep,finishConditionStep,conditionWorkflowStatus,cancelConditionWorkflow,cancelConditionPlan,cleanupConditionWorkflows } from '../api/_lib/condition-workflow-store';
import { runConditionWorkflow } from '../api/_lib/condition-workflow-worker';
import { database,claim,settle } from '../api/_lib/ledger';
import { readUsage } from '../api/v1/health-processing/usage';
const uuid=(n:number)=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const contract={instructions:'Synthetic source-backed mapping contract',response_format:{type:'json_schema',json_schema:{name:'fixture',strict:true,schema:{type:'object',properties:{},additionalProperties:false}}}};
function plan(title='Follow-up for this pregnancy'):ConditionPlan {
  return {version:1,preserved:{groups:[{name:'Pregnancy',bodySystem:'reproductive',isPrimary:true,reason:'Source episode',entryIDs:[uuid(1)],stableID:uuid(9)}],unassigned:[]},
    contextEntries:[{id:uuid(1),title:'Pregnancy',details:'Explicit ongoing pregnancy',excerpt:'Pregnant'}],
    batches:[[{id:uuid(2),title,excerpt:title,patientAssigned:false}]],mapping:contract,verification:contract};
}
const mapped=JSON.stringify({groups:[{name:'Pregnancy',bodySystem:'reproductive',isPrimary:false,reason:'Explicit pregnancy care',entryIDs:['r1'],stableID:'invented'}],unassigned:[]});
const verified=(supported=true)=>JSON.stringify({decisions:[{name:'Pregnancy',bodySystem:'reproductive',nameSupported:true,supportedEntryIDs:supported?['r1']:[],reason:'Source episode checked'}]});
test('mapping then independent verification retains source IDs, reasons and stable identity',()=>{
  const p=validateConditionPlan(plan());let s=initialConditionState(p);
  const input=nextConditionRequest(p,s)!.payload.input;
  assert.ok(!input.includes(uuid(2)));assert.ok(input.includes('r1'));
  s=acceptConditionResponse(p,s,mapped);
  const verifier=JSON.parse(nextConditionRequest(p,s)!.payload.input);
  assert.equal(verifier.groups[0].acceptedContext[0].title,'Pregnancy');
  assert.equal(verifier.groups[0].acceptedContext[0].id,undefined);
  assert.equal(verifier.groups[0].reason,undefined,'Independent checking must not receive the mapper rationale');
  s=acceptConditionResponse(p,JSON.parse(JSON.stringify(s)),verified());
  assert.equal(s.phase,'completed');assert.equal(s.result.groups[0].stableID,uuid(9));
  assert.deepEqual(s.result.groups[0].entryIDs,[uuid(1),uuid(2)]);
  assert.deepEqual(s.result.groups[0].entryReasons,[uuid(2),'Source episode checked']);
});
test('weak links are rejected without altering accepted associations',()=>{
  const p=validateConditionPlan(plan('Unrelated test on the same date'));
  const s=acceptConditionResponse(p,acceptConditionResponse(p,initialConditionState(p),mapped),verified(false));
  assert.deepEqual(s.result.groups[0].entryIDs,[uuid(1)]);assert.deepEqual(s.result.unassigned,[uuid(2)]);
});
test('invalid coverage, invented IDs, renamed verification and manual candidates fail closed',()=>{
  const p=plan(),s=initialConditionState(p);
  assert.throws(()=>acceptConditionResponse(p,s,mapped.replace('r1','r999')));
  assert.throws(()=>acceptConditionResponse(p,s,'{"groups":[],"unassigned":[]}'));
  const checking=acceptConditionResponse(p,s,mapped);
  assert.throws(()=>acceptConditionResponse(p,checking,verified().replace('Pregnancy','Invented diagnosis')));
  p.batches[0][0].patientAssigned=true;assert.throws(()=>validateConditionPlan(p));
});
test('unchanged plan requires zero requests; all-unassigned batch skips verification',()=>{
  const p=plan();p.batches=[];
  assert.equal(nextConditionRequest(p,initialConditionState(p)),null);
  const changed=plan();const s=acceptConditionResponse(changed,initialConditionState(changed),JSON.stringify({groups:[],unassigned:['r1']}));
  assert.equal(s.phase,'completed');assert.deepEqual(s.result.unassigned,[uuid(2)]);
});
test('request plan validates malformed shapes and preserves canonical concern identity',()=>{
  for(const value of [null,{}, {version:1,batches:[null],preserved:{groups:[],unassigned:[]},contextEntries:[]}])
    assert.throws(()=>validateConditionPlan(value),/invalid_condition_workflow/);
  const p=plan();p.preserved.groups[0].name='Migraines';p.preserved.groups[0].bodySystem='neurological';
  const mapping=mapped.replace('Pregnancy','Migraine').replace('reproductive','neurological');
  const verify=verified().replace('Pregnancy','Migraine').replace('reproductive','neurological');
  const s=acceptConditionResponse(p,acceptConditionResponse(p,initialConditionState(p),mapping),verify);
  assert.equal(s.result.groups.length,1);assert.equal(s.result.groups[0].name,'Migraines');
  assert.equal(s.result.groups[0].stableID,uuid(9));
});
test('PostgreSQL workflow continuation, interruption, concurrency, cancellation and uncertain budget',{
  skip:!process.env.AI_WORKFLOW_TEST_DATABASE_URL,
},async()=>{
  process.env.DATABASE_URL=process.env.AI_WORKFLOW_TEST_DATABASE_URL;
  process.env.AI_DEDUPE_SECRET='workflow-test-only';process.env.AI_BUDGET_ID='evaluation-v1';
  process.env.AI_DURABLE_ENABLED='true';process.env.AI_QUEUE_ENABLED='true';process.env.AI_CONDITION_WORKFLOWS_ENABLED='true';
  const db=database();
  try {
    assert.equal((await db.query("SELECT tablename FROM pg_tables WHERE schemaname='public'")).rows.length,0,'Use a dedicated empty test database');
    for(const file of ['001_ai_ledger.sql','002_condition_workflows.sql','003_workflow_cost_attribution.sql','004_workload_types.sql','005_workflow_model.sql','006_workflow_reasoning.sql']) await db.query(await readFile(`migrations/${file}`,'utf8'));
    const submitted=await Promise.all(Array.from({length:5},()=>submitConditionWorkflow('synthetic-owner',plan())));
    const id=submitted[0].id;assert.equal(new Set(submitted.map(w=>w.id)).size,1);
    assert.equal((await readUsage('synthetic-owner','UTC')).budgets[0].id,'evaluation-v1','Queued parents expose applicable budget before any paid step');
    assert.equal(await conditionWorkflowStatus('other-owner',id),undefined);
    const children=await Promise.all([prepareConditionStep(id),prepareConditionStep(id)]);
    assert.equal(children[0],children[1]);
    const deliveries:{id:string;revision:number}[]=[];let calls=0;
    const enqueue=async(id:string,revision:number)=>{deliveries.push({id,revision});};
    const execute=async(child:string)=>{
      const job=await claim(child);if(!job)return 0;calls++;
      await settle(child,'completed',{input_tokens:100,output_tokens:20},job.stage==='condition-synthesis'?mapped:verified());return 1;
    };
    // Worker dies after paid response is durably saved, before advancing parent.
    await assert.rejects(runConditionWorkflow(id,async child=>{await execute(child);throw new Error('simulated interruption');},enqueue));
    await runConditionWorkflow(id,execute,enqueue);assert.equal(calls,1);assert.equal(deliveries.length,1);
    // The next delivery is server-scheduled; no phone request is involved.
    await runConditionWorkflow(deliveries.shift()!.id,execute,enqueue);
    const complete=await conditionWorkflowStatus('synthetic-owner',id);
    assert.equal(complete.state,'completed');assert.equal(calls,2);
    assert.equal(JSON.parse(complete.result.output).groups[0].entryIDs.length,2);
    const usage=await readUsage('synthetic-owner','America/New_York');
    assert.equal(usage.latest_job.id,id);
    assert.equal(usage.latest_job.state,'completed');
    assert.equal(usage.latest_job.cost_nusd,'54000','Parent cost includes both mapping and verification');
    assert.equal(usage.lifetime_nusd,'54000','Parent display must not double-count ledger spending');
    assert.equal(usage.entries.length,2,'Child ledger entries remain the source of spending totals');
    assert.equal((await readUsage('other-owner','UTC')).latest_job,null);
    assert.ok(!JSON.stringify(usage).includes('Pregnancy'),'Usage must exclude clinical text');
    assert.equal((await submitConditionWorkflow('synthetic-owner',plan())).id,id);
    await runConditionWorkflow(id,execute,enqueue);assert.equal(calls,2);
    const reusedPlan=plan();reusedPlan.preserved.groups[0].reason='Presentation explanation changed';
    const reused=await submitConditionWorkflow('synthetic-owner',reusedPlan);
    await runConditionWorkflow(reused.id,execute,enqueue);
    await runConditionWorkflow(reused.id,execute,enqueue);
    assert.equal(calls,2,'Reused child results incur no new inference');
    const reusedUsage=await readUsage('synthetic-owner','UTC');
    assert.equal(reusedUsage.latest_job.id,reused.id);
    assert.equal(reusedUsage.latest_job.cost_nusd,'0','Do not charge a new parent for previously paid child results');
    assert.equal(reusedUsage.lifetime_nusd,'54000');
    // Policy changes neither rebuild accepted results nor change an in-flight model.
    process.env.AI_CONDITION_MODEL='gpt-6-luna';
    process.env.AI_CONDITION_REASONING='medium';
    assert.equal((await submitConditionWorkflow('synthetic-owner',{...plan(),workload_type:'development'})).id,id);
    const luna=await submitConditionWorkflow('synthetic-luna',{...plan(),workload_type:'development'});
    process.env.AI_CONDITION_MODEL='gpt-4o-mini';
    process.env.AI_CONDITION_REASONING='low';
    const lunaChild=await prepareConditionStep(luna.id);
    const pinned=(await db.query('SELECT model,workload_type,reserve_nusd,reasoning_effort FROM ai_jobs WHERE id=$1',[lunaChild])).rows[0];
    assert.equal(pinned.reasoning_effort,'medium');
    assert.equal(pinned.model,'gpt-6-luna');assert.equal(pinned.workload_type,'development');
    assert.equal(pinned.reserve_nusd,'214500000');
    await runConditionWorkflow(luna.id,execute,enqueue);
    await runConditionWorkflow(luna.id,execute,enqueue);
    const lunaUsage=await readUsage('synthetic-luna','UTC');
    assert.equal(lunaUsage.latest_job.workload_type,'development');
    assert.equal(lunaUsage.lifetime_nusd,'40000');
    assert.ok(lunaUsage.entries.every((e:any)=>e.model==='gpt-6-luna'&&e.workload_type==='development'));
    const handoff=await submitConditionWorkflow('synthetic-owner',plan('Postpartum follow-up for this pregnancy'));
    await assert.rejects(runConditionWorkflow(handoff.id,execute,async()=>{throw new Error('queue unavailable');}));
    const afterMapping=calls;
    await runConditionWorkflow(handoff.id,execute,enqueue);
    assert.equal(calls,afterMapping+1,'Failed publication must not repeat mapping');
    assert.equal((await conditionWorkflowStatus('synthetic-owner',handoff.id)).state,'completed');
    const uncertain=await submitConditionWorkflow('synthetic-owner',plan('Different pregnancy care'));
    await runConditionWorkflow(uncertain.id,async child=>{assert.ok(await claim(child));await settle(child,'uncertain');return 1;},enqueue);
    assert.equal((await conditionWorkflowStatus('synthetic-owner',uncertain.id)).state,'uncertain');
    assert.equal((await readUsage('synthetic-owner','UTC')).latest_job.cost_nusd,null);
    assert.ok(BigInt((await db.query('SELECT reserved_nusd FROM ai_budgets WHERE id=$1',['evaluation-v1'])).rows[0].reserved_nusd)>0n);
    await runConditionWorkflow(uncertain.id,()=>{throw new Error('Must never redispatch uncertain inference');},enqueue);
    const cancelled=await submitConditionWorkflow('synthetic-owner',plan('Cancelled care'));
    const child=await prepareConditionStep(cancelled.id);
    await cancelConditionWorkflow('other-owner',cancelled.id);
    assert.equal((await conditionWorkflowStatus('synthetic-owner',cancelled.id)).state,'running');
    await cancelConditionWorkflow('synthetic-owner',cancelled.id);assert.equal(await claim(child!),null);
    assert.equal((await conditionWorkflowStatus('synthetic-owner',cancelled.id)).state,'cancelled');
    assert.equal((await readUsage('synthetic-owner','UTC')).latest_job.cost_nusd,'0','Never-dispatched cancelled work has a known zero charge');
    const expired=await submitConditionWorkflow('synthetic-owner',plan('Expired care'));
    const stoppedPlan=plan('Stopped before submission');
    const stopped=await cancelConditionPlan('synthetic-owner',stoppedPlan);
    assert.equal(stopped.state,'cancelled');
    assert.equal((await submitConditionWorkflow('synthetic-owner',stoppedPlan)).state,'cancelled');
    assert.equal(await prepareConditionStep(stopped.id),null);
    assert.equal((await db.query('SELECT 1 FROM ai_condition_workflow_payloads WHERE workflow_id=$1',[stopped.id])).rows.length,0);
    const racingPlan=plan('Concurrent Stop and submission');
    const [racing]=await Promise.all([submitConditionWorkflow('synthetic-owner',racingPlan),cancelConditionPlan('synthetic-owner',racingPlan)]);
    assert.equal((await conditionWorkflowStatus('synthetic-owner',racing.id)).state,'cancelled');
    await db.query("UPDATE ai_condition_workflow_payloads SET expires_at=now()-interval '1 second' WHERE workflow_id=$1",[expired.id]);
    await cleanupConditionWorkflows();assert.equal((await conditionWorkflowStatus('synthetic-owner',expired.id)).state,'expired');
    assert.equal((await db.query('SELECT * FROM ai_condition_workflow_payloads WHERE workflow_id=$1',[expired.id])).rows.length,0);
    await db.query("INSERT INTO ai_budgets(id,limit_nusd) VALUES('empty-workflow-budget',0)");
    process.env.AI_BUDGET_ID='empty-workflow-budget';
    const unfunded=await submitConditionWorkflow('synthetic-owner',plan('Unfunded care'));
    await runConditionWorkflow(unfunded.id,()=>{throw new Error('Unfunded inference must not execute');},enqueue);
    assert.equal((await conditionWorkflowStatus('synthetic-owner',unfunded.id)).state,'budget_exhausted');
    assert.equal((await db.query('SELECT * FROM ai_condition_workflow_steps WHERE workflow_id=$1',[unfunded.id])).rows.length,0);
  } finally {await db.end();}
});
