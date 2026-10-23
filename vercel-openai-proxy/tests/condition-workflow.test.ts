import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { compactConditionEvidence,compactConditionPlan,ConditionPlan,validateConditionPlan,initialConditionState,nextConditionRequest,acceptConditionResponse,repairVerificationContract } from '../api/_lib/condition-workflow';
import { prepareConditionPlan,submitConditionWorkflow,prepareConditionStep,finishConditionStep,conditionWorkflowStatus,cancelConditionWorkflow,cancelConditionPlan,cleanupConditionWorkflows,resumeConditionWorkflow } from '../api/_lib/condition-workflow-store';
import { runConditionWorkflow } from '../api/_lib/condition-workflow-worker';
import { database,claim,settle } from '../api/_lib/ledger';
import { readUsage } from '../api/v1/health-processing/usage';
import {conditionUpload,cleanupConditionUploads} from '../api/_lib/condition-upload';
import {createHash} from 'node:crypto';
const uuid=(n:number)=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const contract={instructions:'Synthetic source-backed mapping contract',response_format:{type:'json_schema',json_schema:{name:'fixture',strict:true,schema:{type:'object',properties:{},additionalProperties:false}}}};
function plan(title='Follow-up for this pregnancy'):ConditionPlan {
  return {version:1,preserved:{groups:[{name:'Pregnancy',bodySystem:'reproductive',isPrimary:true,reason:'Source episode',entryIDs:[uuid(1)],stableID:uuid(9)}],unassigned:[]},
    contextEntries:[{id:uuid(1),title:'Pregnancy',details:'Explicit ongoing pregnancy',excerpt:'Pregnant'}],
    batches:[[{id:uuid(2),title,excerpt:title,patientAssigned:false}]],mapping:contract,verification:contract};
}
const mapped=JSON.stringify({groups:[{name:'Pregnancy',bodySystem:'reproductive',isPrimary:false,reason:'Explicit pregnancy care',entryIDs:['r1'],stableID:'invented'}],unassigned:[]});
const verified=(supported=true)=>JSON.stringify({decisions:[{name:'Pregnancy',bodySystem:'reproductive',nameSupported:true,supportedEntryIDs:supported?['r1']:[],reason:'Source episode checked'}]});
test('client revision survives identity validation without changing model input',()=>{
  const original=validateConditionPlan(plan());
  const revised=validateConditionPlan({...original,clientRevision:'condition-exact-heading-v2'});
  assert.equal(revised.clientRevision,'condition-exact-heading-v2');
  assert.deepEqual(nextConditionRequest(original,initialConditionState(original)),nextConditionRequest(revised,initialConditionState(revised)));
  for(const clientRevision of [12,'','x'.repeat(81),'unexpected revision'])
    assert.throws(()=>validateConditionPlan({...original,clientRevision}));
});
test('identical disjoint headings coalesce structurally but every link is independently checked',()=>{
  const p=plan();p.batches[0].push({id:uuid(3),title:'Unrelated observation'});
  const a=JSON.parse(mapped).groups[0],b={...a,reason:'Separate mapper rationale',entryIDs:['r2']};
  const checking=acceptConditionResponse(p,initialConditionState(p),JSON.stringify({groups:[a,b],unassigned:[]}));
  assert.equal(checking.coverageRetry,undefined);
  const groups=JSON.parse(nextConditionRequest(p,checking)!.payload.input).groups;
  assert.equal(groups.length,1);assert.equal(groups[0].entries.length,2);
  assert.equal(groups[0].reason,undefined);
  const done=acceptConditionResponse(p,checking,verified());
  assert.equal(done.phase,'completed');
  assert.deepEqual(done.result.groups[0].entryIDs,[uuid(1),uuid(2)]);
  assert.deepEqual(done.result.unassigned,[uuid(3)]);
});
test('heading consolidation cannot resolve overlap, priority conflicts or nonidentical aliases',()=>{
  const p=plan();p.batches[0].push({id:uuid(3),title:'Another observation'});
  const a=JSON.parse(mapped).groups[0];
  for(const b of [{...a},{...a,entryIDs:['r2'],isPrimary:true}])
    assert.throws(()=>acceptConditionResponse(p,initialConditionState(p),JSON.stringify({groups:[a,b],unassigned:[]})));
  const first={...a,name:'Headache',bodySystem:'neurological'},second={...first,name:'Headaches',entryIDs:['r2']};
  assert.throws(()=>acceptConditionResponse(p,initialConditionState(p),JSON.stringify({groups:[first,second],unassigned:[]})));
});
test('empty mapper headings are omitted without losing source coverage or accepting links',()=>{
  const p=plan(),group=JSON.parse(mapped).groups[0];
  const response={groups:[{...group,name:'Unused concern',entryIDs:[]},group],unassigned:[]};
  const checking=acceptConditionResponse(p,initialConditionState(p),JSON.stringify(response));
  assert.equal(checking.phase,'verification');assert.equal(checking.proposal!.groups.length,1);
  assert.deepEqual(checking.result,p.preserved);
  assert.equal(JSON.parse(nextConditionRequest(p,checking)!.payload.input).groups[0].entries.length,1);
  const missing=JSON.stringify({...response,groups:[response.groups[0]]});
  const retry=acceptConditionResponse(p,initialConditionState(p),missing);
  assert.equal(retry.coverageRetry,true);assert.deepEqual(retry.result,p.preserved);
  assert.throws(()=>acceptConditionResponse(p,retry,missing));
  assert.throws(()=>acceptConditionResponse(p,initialConditionState(p),JSON.stringify({...response,groups:[{...response.groups[0],bodySystem:'invented'},group]})));
  const done=acceptConditionResponse(p,checking,verified(false));
  assert.deepEqual(done.result.unassigned,[uuid(2)]);
  const badPreserved=structuredClone(p);
  badPreserved.preserved.groups.push({...badPreserved.preserved.groups[0],name:'Empty saved heading',isPrimary:false,entryIDs:[]});
  assert.throws(()=>validateConditionPlan(badPreserved));
});
test('verification preserves occurrence status and hypothetical care without forwarding mapper rationale',()=>{
  const p=plan();
  Object.assign(p.contextEntries[0],{status:'past',statusExplicit:true,actionKind:'treatment_received'});
  Object.assign(p.batches[0][0],{status:'current',statusExplicit:false,actionKind:'uncertain'});
  const state=acceptConditionResponse(p,initialConditionState(p),mapped);
  const group=JSON.parse(nextConditionRequest(p,state)!.payload.input).groups[0];
  assert.equal(group.acceptedContext[0].status,'past');
  assert.equal(group.acceptedContext[0].statusExplicit,true);
  assert.equal(group.entries[0].status,'current');
  assert.equal(group.entries[0].statusExplicit,false);
  assert.equal(group.entries[0].actionKind,'uncertain');
  assert.equal(group.reason,undefined);
});
test('both model stages receive original source windows without adopting mapper explanations',()=>{
  const p=plan();
  p.batches[0][0].sourceWindows=['We are discussing this pregnancy. Return in two weeks.'];
  const initial=initialConditionState(validateConditionPlan(p));
  const mapping=JSON.parse(nextConditionRequest(p,initial)!.payload.input);
  assert.deepEqual(mapping.entries[0].sourceWindows,p.batches[0][0].sourceWindows);
  const checking=acceptConditionResponse(p,initial,mapped);
  const group=JSON.parse(nextConditionRequest(p,checking)!.payload.input).groups[0];
  assert.deepEqual(group.entries[0].sourceWindows,p.batches[0][0].sourceWindows);
  assert.equal(group.reason,undefined);
});
test('large preserved histories keep verifier requests bounded without changing accepted links',()=>{
  const p=plan();
  p.contextEntries=Array.from({length:1200},(_,i)=>({id:uuid(100+i),title:'Pregnancy',excerpt:'Explicit pregnancy episode '+ 'care '.repeat(100)}));
  p.preserved.groups[0].entryIDs=p.contextEntries.map(e=>e.id);
  validateConditionPlan(p);
  const s=acceptConditionResponse(p,initialConditionState(p),mapped);
  const request=nextConditionRequest(p,s)!;
  assert.ok(Buffer.byteLength(request.payload.input)<40000);
  assert.equal(JSON.parse(request.payload.input).groups[0].contextIncomplete,true);
  const done=acceptConditionResponse(p,s,verified());
  assert.equal(done.result.groups[0].entryIDs.length,1201);
});
test('large condition catalogues cannot expand a model request without bound',()=>{
  const p=plan();
  p.contextEntries=Array.from({length:1500},(_,i)=>({id:uuid(100+i),title:`Documented concern ${i}`}));
  p.preserved.groups=p.contextEntries.map((e,i)=>({name:`Documented concern ${i}`,bodySystem:'unknown',isPrimary:false,reason:'Synthetic source',entryIDs:[e.id]}));
  const s=initialConditionState(validateConditionPlan(p));
  const request=nextConditionRequest(p,s)!;
  assert.ok(Buffer.byteLength(request.payload.input)<40000);
  assert.equal(JSON.parse(request.payload.input).catalogueIncomplete,true);
  assert.equal(s.result.groups.length,1500,'Catalogue selection never deletes saved groups');
});
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
  const retry=acceptConditionResponse(p,s,'{"groups":[],"unassigned":[]}');
  assert.equal(retry.coverageRetry,true);
  assert.throws(()=>acceptConditionResponse(p,retry,'{"groups":[],"unassigned":[]}'));
  const checking=acceptConditionResponse(p,s,mapped);
  assert.throws(()=>acceptConditionResponse(p,checking,verified().replace('Pregnancy','Invented diagnosis')));
  p.batches[0][0].patientAssigned=true;assert.throws(()=>validateConditionPlan(p));
});
test('one missing-coverage retry preserves state and independently checks the complete replacement',()=>{
  const p=plan();p.batches[0].push({id:uuid(3),title:'Unrelated symptom'});
  p.batches.push([{id:uuid(4),title:'Another record'}]);
  let s=initialConditionState(p);
  const before=structuredClone(s.result);
  s=acceptConditionResponse(p,s,mapped);
  assert.equal(s.phase,'mapping');assert.equal(s.coverageRetry,true);
  assert.equal(s.proposal,undefined);assert.deepEqual(s.result,before);
  const request=nextConditionRequest(p,s)!;
  assert.equal(JSON.parse(request.payload.input).coverageRetry,true);
  assert.match(request.payload.instructions,/only coverage retry/);
  const complete=JSON.parse(mapped);complete.unassigned=['r2'];
  s=acceptConditionResponse(p,s,JSON.stringify(complete));
  assert.equal(s.phase,'verification');
  assert.deepEqual(s.result.groups,before.groups,'No link accepted before independent checking');
  s=acceptConditionResponse(p,s,verified());
  assert.equal(s.batch,1);assert.equal(s.coverageRetry,undefined);
  assert.deepEqual(s.result.groups[0].entryIDs,[uuid(1),uuid(2)]);
  assert.deepEqual(s.result.unassigned,[uuid(3)]);
  assert.equal(JSON.parse(nextConditionRequest(p,s)!.payload.input).coverageRetry,undefined);
});
test('duplicate or conflicting mappings cannot use coverage recovery',()=>{
  const p=plan();const s=initialConditionState(p);
  assert.throws(()=>acceptConditionResponse(p,s,'{"groups":[],"unassigned":["r1","r1"]}'));
  const conflicting=JSON.parse(mapped);conflicting.unassigned=['r1'];
  assert.throws(()=>acceptConditionResponse(p,s,JSON.stringify(conflicting)));
  const invalid=JSON.parse(mapped);invalid.groups[0].name='Normal';invalid.groups[0].entryIDs=[];
  assert.equal(acceptConditionResponse(p,s,JSON.stringify(invalid)).coverageRetry,true,'Empty heading is omitted; missing occurrence receives bounded coverage retry');
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
    for(const file of ['001_ai_ledger.sql','002_condition_workflows.sql','003_workflow_cost_attribution.sql','004_workload_types.sql','005_workflow_model.sql','006_workflow_reasoning.sql','007_condition_uploads.sql']) await db.query(await readFile(`migrations/${file}`,'utf8'));
    const largeUploadPlan=plan('Upload-only synthetic care');
    largeUploadPlan.batches=Array.from({length:430},(_,i)=>[{id:uuid(5000+i),title:'Synthetic record',excerpt:'source '.repeat(135)}]);
    const uploadData=Buffer.from(JSON.stringify(largeUploadPlan));
    assert.ok(uploadData.length>400000 && uploadData.length<480000);
    const digest=createHash('sha256').update(uploadData).digest('hex');
    const upload={digest,count:2};const middle=Math.floor(uploadData.length/2);
    await conditionUpload('upload-owner',{...upload,operation:'part',index:0,content:uploadData.subarray(0,middle).toString('base64')});
    assert.deepEqual((await conditionUpload('upload-owner',{...upload,operation:'status'})).received,[0]);
    await assert.rejects(conditionUpload('upload-owner',{...upload,operation:'finish'}));
    assert.equal((await db.query('SELECT count(*) FROM ai_jobs')).rows[0].count,'0');
    await conditionUpload('upload-owner',{...upload,operation:'part',index:1,content:uploadData.subarray(middle).toString('base64')});
    const finalized=await Promise.all([conditionUpload('upload-owner',{...upload,operation:'finish'}),conditionUpload('upload-owner',{...upload,operation:'finish'})]);
    assert.equal(finalized[0].id,finalized[1].id);
    assert.equal((await db.query('SELECT count(*) FROM ai_jobs')).rows[0].count,'0','Upload and finalization never dispatch inference');
    const bigResult={groups:[],unassigned:Array.from({length:15000},(_,i)=>uuid(20000+i))};
    await db.query("UPDATE ai_condition_workflows SET state='completed' WHERE id=$1",[finalized[0].id]);
    await db.query('UPDATE ai_condition_workflow_payloads SET checkpoint=$2 WHERE workflow_id=$1',[finalized[0].id,{result:bigResult}]);
    const manifest=await conditionWorkflowStatus('upload-owner',finalized[0].id);
    assert.ok(manifest.result.chunkCount>1);assert.equal(manifest.result.output,undefined);
    const received=[];
    for(let i=0;i<manifest.result.chunkCount;i++) received.push(Buffer.from((await conditionWorkflowStatus('upload-owner',finalized[0].id,i)).result.chunk,'base64'));
    const downloaded=Buffer.concat(received);
    assert.equal(createHash('sha256').update(downloaded).digest('hex'),manifest.result.digest);
    assert.deepEqual(JSON.parse(downloaded.toString()),bigResult);
    assert.equal(await conditionWorkflowStatus('other-upload-owner',finalized[0].id,0),undefined);
    await db.query("UPDATE ai_condition_workflows SET state='queued' WHERE id=$1",[finalized[0].id]);
    assert.equal((await conditionUpload('other-upload-owner',{...upload,operation:'status'})).workflow_id,undefined);
    await conditionUpload('other-upload-owner',{...upload,operation:'cancel'});
    assert.equal((await conditionUpload('other-upload-owner',{...upload,operation:'part',index:0,content:uploadData.subarray(0,middle).toString('base64')})).state,'cancelled');
    await conditionUpload('upload-owner',{...upload,operation:'cancel'});
    assert.equal((await conditionWorkflowStatus('upload-owner',finalized[0].id)).state,'cancelled');
    await conditionUpload('expiry-upload-owner',{...upload,operation:'part',index:0,content:uploadData.subarray(0,middle).toString('base64')});
    await db.query("UPDATE ai_condition_uploads SET expires_at=now()-interval '1 second' WHERE owner='expiry-upload-owner'");
    await cleanupConditionUploads();
    assert.equal((await conditionUpload('expiry-upload-owner',{...upload,operation:'status'})).state,'expired');
    assert.equal((await db.query("SELECT count(*) FROM ai_condition_upload_parts WHERE owner='expiry-upload-owner'")).rows[0].count,'0');
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

    process.env.AI_BUDGET_ID='evaluation-v1';
    const recoverPlan=plan('Synthetic recovery'),recover=await submitConditionWorkflow('recover-owner',recoverPlan);
    const checking=acceptConditionResponse(recoverPlan,initialConditionState(recoverPlan),mapped);
    await db.query('UPDATE ai_condition_workflow_payloads SET checkpoint=$2 WHERE workflow_id=$1',[recover.id,checking]);
    const failedChild=await prepareConditionStep(recover.id);
    const claimed=await claim(failedChild!);assert.ok(claimed);
    await settle(failedChild!,'completed',{input_tokens:100,output_tokens:20},verified().replace('["r1"]','["r1","r8"]'));
    // Emulate the old server's terminal transition, without changing its paid child.
    await db.query("UPDATE ai_condition_workflows SET state='invalid',revision=1,current_step=NULL,finished_at=now() WHERE id=$1",[recover.id]);
    const beforeBudget=(await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets')).rows;
    assert.equal((await conditionWorkflowStatus('recover-owner',recover.id)).state,'invalid','GET never resumes work');
    assert.equal(await resumeConditionWorkflow('wrong-owner',recover.id),null);
    const resumed=await Promise.all([resumeConditionWorkflow('recover-owner',recover.id),resumeConditionWorkflow('recover-owner',recover.id)]);
    assert.equal(resumed[0].revision,2);assert.equal(resumed[1].revision,2);
    assert.equal(resumed[0].state,'queued');
    assert.deepEqual((await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets')).rows,beforeBudget);
    const repairChild=await prepareConditionStep(recover.id);assert.notEqual(repairChild,failedChild);
    assert.ok(await claim(repairChild!));
    await settle(repairChild!,'completed',{input_tokens:100,output_tokens:20},JSON.stringify({decisions:{g0:{ok:true,entries:['r1'],reason:null}}}));
    assert.equal((await finishConditionStep(recover.id,repairChild!))!.state,'completed');
    assert.equal((await resumeConditionWorkflow('recover-owner',recover.id)).state,'completed');

    // Replay an already-paid mapping rejected by the obsolete heading-word gate.
    const headingPlan=plan('Report heading recovery'),headingRun=await submitConditionWorkflow('heading-owner',headingPlan);
    const headingChild=await prepareConditionStep(headingRun.id);assert.ok(await claim(headingChild!));
    const headingOutput=JSON.parse(mapped);headingOutput.groups[0].name='Screening test findings';
    await settle(headingChild!,'completed',{input_tokens:100,output_tokens:20},JSON.stringify(headingOutput));
    await db.query("UPDATE ai_condition_workflows SET state='invalid',revision=1,current_step=NULL,finished_at=now() WHERE id=$1",[headingRun.id]);
    const headingBudget=(await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets')).rows;
    const headingResume=await Promise.all([resumeConditionWorkflow('heading-owner',headingRun.id),resumeConditionWorkflow('heading-owner',headingRun.id)]);
    assert.ok(headingResume.every(r=>r.state==='queued' && r.revision===2));
    assert.deepEqual((await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets')).rows,headingBudget);
    const headingCheckpoint=(await db.query('SELECT checkpoint FROM ai_condition_workflow_payloads WHERE workflow_id=$1',[headingRun.id])).rows[0].checkpoint;
    assert.equal(headingCheckpoint.phase,'verification');assert.deepEqual(headingCheckpoint.result,headingPlan.preserved);
    const headingCheck=await prepareConditionStep(headingRun.id);assert.notEqual(headingCheck,headingChild);
    assert.ok(await claim(headingCheck!));
    await settle(headingCheck!,'completed',{input_tokens:100,output_tokens:20},JSON.stringify({decisions:[{name:'Screening test findings',bodySystem:'reproductive',nameSupported:false,supportedEntryIDs:[],reason:'Report heading is not a patient concern.'}]}));
    assert.equal((await finishConditionStep(headingRun.id,headingCheck!))!.state,'completed');
    const headingResult=(await db.query('SELECT checkpoint FROM ai_condition_workflow_payloads WHERE workflow_id=$1',[headingRun.id])).rows[0].checkpoint.result;
    assert.deepEqual(headingResult.groups,headingPlan.preserved.groups);assert.deepEqual(headingResult.unassigned,[uuid(2)]);

    // Regression: October 23 reused an October 12 completed mapper whose result
    // had been purged. Replay with synthetic data and the real database ledger.
    for (const removed of [false,true]) {
      const owner=`expired-result-${removed}`, p=plan('Expired cached mapping');
      const old=await submitConditionWorkflow(owner,p);
      const oldChild=(await prepareConditionStep(old.id))!;
      assert.ok(await claim(oldChild));
      await settle(oldChild,'completed',{input_tokens:100,output_tokens:20},mapped);
      if (removed) await db.query('DELETE FROM ai_payloads WHERE job_id=$1',[oldChild]);
      else await db.query("UPDATE ai_payloads SET expires_at=now()-interval '1 second' WHERE job_id=$1",[oldChild]);
      await db.query("UPDATE ai_condition_workflows SET state='invalid',revision=1,current_step=NULL,finished_at=now() WHERE id=$1",[old.id]);
      const budgetBefore=(await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets')).rows;
      assert.equal((await conditionWorkflowStatus(owner,old.id)).state,'invalid');
      const resumed=await Promise.all([resumeConditionWorkflow(owner,old.id),resumeConditionWorkflow(owner,old.id)]);
      assert.ok(resumed.every(r=>r.state==='queued' && r.revision===2));
      assert.deepEqual((await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets')).rows,budgetBefore);
      const children=await Promise.all([prepareConditionStep(old.id),prepareConditionStep(old.id)]);
      assert.equal(children[0],children[1]);assert.notEqual(children[0],oldChild);
      assert.ok(await claim(children[0]!));assert.equal(await claim(children[0]!),null);
      await settle(children[0]!,'completed',{input_tokens:100,output_tokens:20},mapped);
      assert.equal((await finishConditionStep(old.id,children[0]!))!.state,'running');
      const check=(await prepareConditionStep(old.id))!;assert.ok(await claim(check));
      await settle(check,'completed',{input_tokens:100,output_tokens:20},verified());
      assert.equal((await finishConditionStep(old.id,check))!.state,'completed');
      const result=JSON.parse((await conditionWorkflowStatus(owner,old.id)).result.output);
      assert.deepEqual(result.groups[0].entryIDs,[uuid(1),uuid(2)]);
      // A fresh parent must also avoid the original expired shared result.
      const fresh=await submitConditionWorkflow(owner,{...p,clientRevision:'expiry-regression-v1'});
      const freshChild=(await prepareConditionStep(fresh.id))!;assert.notEqual(freshChild,oldChild);
      assert.ok(await claim(freshChild));
      await settle(freshChild,'uncertain');
      await finishConditionStep(fresh.id,freshChild);
      assert.equal((await resumeConditionWorkflow(owner,fresh.id)).state,'uncertain');
    }

    // Full-size workflow: fail early, midway and on the last verification batch.
    // Run the real durable worker/store/ledger with a synthetic provider, no API.
    const longPlan=plan('Long workflow');
    longPlan.batches=Array.from({length:45},(_,i)=>[{id:uuid(1000+i),title:`Synthetic occurrence ${i}`}]);
    const long=await submitConditionWorkflow('long-owner',longPlan);
    const paidIDs=new Set<string>(),perStage={mapping:0,verification:0,repair:0};
    const expectedUnassigned:string[]=[];let crashInjected=false,queueFailure=false;
    const longExecute=async(child:string)=>{
      const job=await claim(child);if(!job)return 0;
      assert.ok(!paidIDs.has(child),'A paid child must never execute twice');paidIDs.add(child);
      const {payload}=(await db.query('SELECT payload FROM ai_payloads WHERE job_id=$1',[child])).rows[0];
      const checkpoint=(await db.query('SELECT checkpoint FROM ai_condition_workflow_payloads WHERE workflow_id=$1',[long.id])).rows[0].checkpoint;
      const batch=checkpoint.batch;let output:string;
      if(payload.stage==='condition-synthesis') {perStage.mapping++;output=mapped;}
      else if(checkpoint.verificationRepair) {
        perStage.repair++;
        const reject=batch===22;if(reject)expectedUnassigned.push(uuid(1000+batch));
        output=JSON.stringify({decisions:{g0:{ok:!reject,entries:reject?[]:['r1'],reason:reject?'Wrong-person attribution.':null}}});
      } else {
        perStage.verification++;
        output=batch===0?verified().replace('["r1"]','["r1","r99"]'):
          [22,44].includes(batch)?verified().replace('"name":"Pregnancy"','"name":"Renamed concern"'):verified();
      }
      await settle(child,'completed',{input_tokens:100,output_tokens:20},output);
      if(checkpoint.batch===10 && !crashInjected) {crashInjected=true;throw new Error('test_process_exit');}
      return 1;
    };
    for(let deliveries=0;deliveries<110;deliveries++) {
      try {
        await runConditionWorkflow(long.id,longExecute,async()=>{
          const w=await conditionWorkflowStatus('long-owner',long.id);
          if(w.revision===31 && !queueFailure) {queueFailure=true;throw new Error('test_queue_failure');}
        });
      } catch(error) {assert.ok(['test_process_exit','test_queue_failure'].includes((error as Error).message));}
      const status=await conditionWorkflowStatus('long-owner',long.id);
      if(status.state==='completed')break;
      assert.ok(['running','queued'].includes(status.state),'No hidden terminal failure in a recoverable run');
      // Retrying submission and polling cannot replay a completed provider request.
      const snapshot=(await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets WHERE id=$1',['evaluation-v1'])).rows;
      await Promise.all([submitConditionWorkflow('long-owner',longPlan),submitConditionWorkflow('long-owner',longPlan),conditionWorkflowStatus('long-owner',long.id)]);
      assert.deepEqual((await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets WHERE id=$1',['evaluation-v1'])).rows,snapshot);
    }
    const longDone=await conditionWorkflowStatus('long-owner',long.id);
    assert.equal(longDone.state,'completed');assert.ok(crashInjected && queueFailure);
    assert.deepEqual(perStage,{mapping:45,verification:45,repair:3});assert.equal(paidIDs.size,93);
    const final=JSON.parse(longDone.result.output);
    assert.deepEqual(final.unassigned,expectedUnassigned);
    assert.deepEqual(final.groups[0].entryIDs,[uuid(1),...longPlan.batches.flat().map(e=>e.id).filter(id=>!expectedUnassigned.includes(id))]);
    assert.equal(new Set([...final.groups.flatMap((g:any)=>g.entryIDs),...final.unassigned]).size,46);

    // A malformed repair stops; repeated button taps may not buy endless repairs.
    const exhaustedPlan=plan('Exhausted repair'),exhausted=await submitConditionWorkflow('repair-exhausted-owner',exhaustedPlan);
    let exhaustedCalls=0;
    for(let i=0;i<3;i++) await runConditionWorkflow(exhausted.id,async child=>{
      const job=await claim(child);if(!job)return 0;exhaustedCalls++;
      await settle(child,'completed',{input_tokens:100,output_tokens:20},i===0?mapped:i===1?verified().replace('["r1"]','["r99"]'):'{"decisions":');return 1;
    },async()=>{});
    assert.equal((await conditionWorkflowStatus('repair-exhausted-owner',exhausted.id)).state,'invalid');
    const retained=(await db.query('SELECT checkpoint FROM ai_condition_workflow_payloads WHERE workflow_id=$1',[exhausted.id])).rows[0].checkpoint;
    assert.deepEqual(retained.result,exhaustedPlan.preserved);
    const balance=(await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets')).rows;
    for(let i=0;i<3;i++) {
      assert.equal((await submitConditionWorkflow('repair-exhausted-owner',exhaustedPlan)).state,'invalid');
      await runConditionWorkflow(exhausted.id,async()=>{throw new Error('Must not execute exhausted repair');},async()=>{});
    }
    assert.equal(exhaustedCalls,3);assert.deepEqual((await db.query('SELECT used_nusd,reserved_nusd FROM ai_budgets')).rows,balance);
  } finally {await db.end();}
});


test('rejected heading gets one fresh mapping and independent verification while old links stay fixed',()=>{
  const p=plan();p.repairRejectedHeadings=true;p.headingRecoveryInstructions='Make one simpler source-supported heading proposal, never repeat rejected names.';
  const original=initialConditionState(validateConditionPlan(p));
  let state=acceptConditionResponse(p,original,mapped);
  const reject=JSON.stringify({decisions:[{name:'Pregnancy',bodySystem:'reproductive',nameSupported:false,supportedEntryIDs:[],reason:'Unsupported heading'}]});
  state=acceptConditionResponse(p,state,reject);
  assert.equal(state.phase,'mapping');assert.equal(state.recoveringHeading,true);
  const input=JSON.parse(nextConditionRequest(p,state)!.payload.input);
  assert.ok(nextConditionRequest(p,state)!.payload.instructions.includes(p.headingRecoveryInstructions!));
  assert.equal(input.headingRecovery,true);assert.deepEqual(input.rejectedHeadings,['Pregnancy']);
  assert.equal(input.entries.length,1);assert.equal(input.entries[0].id,'r1');
  assert.equal(state.result.groups[0].entryIDs.length,1);
  state=acceptConditionResponse(p,JSON.parse(JSON.stringify(state)),mapped.replaceAll('Pregnancy','Reported pelvic pain'));
  assert.equal(state.phase,'verification');
  state=acceptConditionResponse(p,state,verified().replaceAll('Pregnancy','Reported pelvic pain'));
  assert.equal(state.phase,'completed');assert.equal(state.result.groups.length,2);
  assert.deepEqual(state.result.groups[0].entryIDs,[uuid(1)]);
  assert.deepEqual(state.result.groups[1].entryIDs,[uuid(2)]);
});
test('heading recovery cannot retry an unchanged rejected heading or loop after another rejection',()=>{
  for(const unchanged of [true,false]) {
    const p=plan();p.repairRejectedHeadings=true;p.headingRecoveryInstructions='Make one simpler source-supported heading proposal, never repeat rejected names.';
    const rejected=(name:string)=>JSON.stringify({decisions:[{name,bodySystem:'reproductive',nameSupported:false,supportedEntryIDs:[],reason:'No explicit support'}]});
    let s=acceptConditionResponse(p,initialConditionState(p),mapped);
    s=acceptConditionResponse(p,s,rejected('Pregnancy'));
    s=acceptConditionResponse(p,s,unchanged?mapped:mapped.replaceAll('Pregnancy','Pelvic pain'));
    if(!unchanged) s=acceptConditionResponse(p,s,rejected('Pelvic pain'));
    assert.equal(s.phase,'completed');assert.equal(nextConditionRequest(p,s),null);
    assert.deepEqual(s.result.unassigned,[uuid(2)]);
    assert.deepEqual(s.result.groups[0].entryIDs,[uuid(1)]);
  }
});
test('edge rejection does not trigger heading recovery; opt-in is validated',()=>{
  const p=plan();p.repairRejectedHeadings=true;p.headingRecoveryInstructions='Make one simpler source-supported heading proposal, never repeat rejected names.';
  const s=acceptConditionResponse(p,acceptConditionResponse(p,initialConditionState(p),mapped),verified(false));
  assert.equal(s.phase,'completed');assert.deepEqual(s.result.unassigned,[uuid(2)]);
  assert.throws(()=>validateConditionPlan({...p,repairRejectedHeadings:'yes'}));
});

test('heading recovery waits until all ordinary batches finish without changing their requests',()=>{
  const p=plan();p.repairRejectedHeadings=true;p.headingRecoveryInstructions='One simpler descriptive heading, independently checked.';
  p.batches.push([{id:uuid(3),title:'Another pregnancy follow-up',excerpt:'Explicit pregnancy follow-up'}]);
  const control={...p,repairRejectedHeadings:false};
  let candidate=initialConditionState(p), baseline=initialConditionState(control);
  for(let batch=0;batch<2;batch++) {
    assert.deepEqual(nextConditionRequest(p,candidate),nextConditionRequest(control,baseline));
    candidate=acceptConditionResponse(p,candidate,mapped);baseline=acceptConditionResponse(control,baseline,mapped);
    assert.deepEqual(nextConditionRequest(p,candidate),nextConditionRequest(control,baseline));
    const response=batch===0?verified().replace('"nameSupported":true','"nameSupported":false'):verified();
    candidate=acceptConditionResponse(p,candidate,response);baseline=acceptConditionResponse(control,baseline,response);
  }
  assert.equal(baseline.phase,'completed');assert.equal(candidate.recoveringHeading,true);
  const input=JSON.parse(nextConditionRequest(p,candidate)!.payload.input);
  assert.equal(input.entries.length,1);
  assert.equal(input.entries[0].title,p.batches[0][0].title);
  assert.deepEqual(candidate.result.groups[0].entryIDs,[uuid(1),uuid(3)]);
});

test('compact evidence roundtrips exact windows, including negation, medication and wrong-person context',()=>{
 const rows=[{id:uuid(2),sourceWindows:['Patient denies pain. Mother has diabetes.','Take 5 mg only if symptoms return.']},
 {id:uuid(3),sourceWindows:['Patient denies pain. Mother has diabetes.','Patient denies pain. Mother has diabetes.']}];
 const before=structuredClone(rows), packed=compactConditionEvidence({entries:rows});
 assert.equal(packed.sourceWindowTable.length,2);
 assert.deepEqual(packed.entries.map((e:any)=>{const {sourceWindowRefs,...rest}=e;return {...rest,sourceWindows:sourceWindowRefs.map((i:number)=>packed.sourceWindowTable[i])};}),before);
 assert.deepEqual(rows,before);
 assert.throws(()=>compactConditionEvidence({entries:[{sourceWindows:[null]}]}));
});
test('compact plan packs stable occurrences once and is idempotent across durable restart',()=>{
 const p=plan();p.batches=Array.from({length:12},(_,i)=>[{id:uuid(i+2),title:'Separate occurrence',sourceWindows:['Original source. '.repeat(500)]}]);
 const compact=compactConditionPlan(p);
 assert(compact.batches.length<p.batches.length);
 assert.deepEqual(compact.batches.flat(),p.batches.flat());
 assert.deepEqual(compactConditionPlan(compact),compact);
 assert.deepEqual(compact.preserved,p.preserved);
 assert.deepEqual(compact.contextEntries,p.contextEntries);
 assert.equal(p.evidenceEncoding,undefined);
 assert.deepEqual(nextConditionRequest(compact,initialConditionState(compact)),nextConditionRequest(JSON.parse(JSON.stringify(compact)),JSON.parse(JSON.stringify(initialConditionState(compact)))));
 assert.throws(()=>validateConditionPlan({...p,evidenceEncoding:'unknown'}));
});
test('compact verification requires complete group keys, rejects invented evidence and needs rejection reasons',()=>{
 const p=compactConditionPlan(plan());p.batches[0][0].sourceWindows=['If symptoms persist, return.'];
 const initial=initialConditionState(p), checking=acceptConditionResponse(p,initial,mapped);
 assert.deepEqual(checking.result,p.preserved,'Mapping must never publish an unchecked link');
 const request=nextConditionRequest(p,checking)!, input=JSON.parse(request.payload.input);
 assert.equal(input.groups[0].groupID,'g0');assert.equal(input.groups[0].reason,undefined);
 assert.deepEqual(input.sourceWindowTable,['If symptoms persist, return.']);
 const good={decisions:{g0:{ok:true,entries:['r1'],reason:null}}};
 const done=acceptConditionResponse(p,checking,JSON.stringify(good));
 assert.equal(done.phase,'completed');assert.deepEqual(done.result.groups[0].entryIDs,[uuid(1),uuid(2)]);
 for(const bad of [{decisions:{}},{decisions:{g0:{ok:true,entries:['r99'],reason:null}}},
 {decisions:{g0:{ok:true,entries:['r1','r1'],reason:null}}},{decisions:{g0:{ok:false,entries:[],reason:null}}},
 {decisions:{g0:{ok:true,entries:[],reason:null}}},{decisions:{g1:good.decisions.g0}},
 {decisions:{g0:{...good.decisions.g0,extra:1}}}]) assert.throws(()=>acceptConditionResponse(p,checking,JSON.stringify(bad)));
 const rejected=acceptConditionResponse(p,checking,JSON.stringify({decisions:{g0:{ok:false,entries:[],reason:'Wrong person attribution.'}}}));
 assert.deepEqual(rejected.result.groups,p.preserved.groups);assert.deepEqual(rejected.result.unassigned,[uuid(2)]);
});

test('rejected links recover a standalone concern once while accepted links and restart state stay fixed',()=>{
 const p=plan();p.repairRejectedHeadings=true;p.headingRecoveryInstructions='Try a source-supported standalone concern.';p.repairRejectedLinks=true;
 p.batches[0].push({id:uuid(3),title:'Sleep disruption',sourceWindows:['Cough wakes me. The cause is uncertain.']});
 const mappedBoth=JSON.stringify({groups:[{...JSON.parse(mapped).groups[0],entryIDs:['r1','r2']}],unassigned:[]});
 const checking=acceptConditionResponse(p,initialConditionState(validateConditionPlan(p)),mappedBoth);
 const recovering=acceptConditionResponse(p,checking,verified(true));
 assert.equal(recovering.phase,'mapping');assert.equal(recovering.recoveringHeading,true);
 assert.deepEqual(recovering.result.groups[0].entryIDs,[uuid(1),uuid(2)]);
 assert.deepEqual(recovering.headingRecovery!.entryIDs,[uuid(3)]);
 const request=nextConditionRequest(p,recovering)!;
 assert.deepEqual(request,nextConditionRequest(JSON.parse(JSON.stringify(p)),JSON.parse(JSON.stringify(recovering))));
 assert.deepEqual(Object.values(request.map),[uuid(3)]);
 const alternative=JSON.stringify({groups:[{name:'Sleep disruption',bodySystem:'unknown',isPrimary:false,reason:'Explicit sleep concern',entryIDs:['r1']}],unassigned:[]});
 const rechecking=acceptConditionResponse(p,recovering,alternative);
 assert.equal(rechecking.phase,'verification');assert.equal(rechecking.result.groups.length,1);
 const done=acceptConditionResponse(p,rechecking,JSON.stringify({decisions:[{name:'Sleep disruption',bodySystem:'unknown',nameSupported:true,supportedEntryIDs:['r1'],reason:'Original source supports sleep disruption without asserting a cause.'}]}));
 assert.equal(done.phase,'completed');assert.deepEqual(done.result.groups[0].entryIDs,[uuid(1),uuid(2)]);
 assert.deepEqual(done.result.groups[1].entryIDs,[uuid(3)]);assert.deepEqual(done.result.unassigned,[]);
 const repeat=acceptConditionResponse(p,recovering,mapped);
 assert.equal(repeat.phase,'completed');assert.deepEqual(repeat.result.unassigned,[uuid(3)]);
 const rejected=acceptConditionResponse(p,rechecking,JSON.stringify({decisions:[{name:'Sleep disruption',bodySystem:'unknown',nameSupported:false,supportedEntryIDs:[],reason:'Not supported.'}]}));
 assert.equal(rejected.phase,'completed');assert.deepEqual(rejected.result.unassigned,[uuid(3)]);
});
test('link recovery requires explicit opt-in and preserves ordinary unassigned behavior',()=>{
 const p=plan();assert.throws(()=>validateConditionPlan({...p,repairRejectedLinks:true}));
 assert.throws(()=>validateConditionPlan({...p,repairRejectedLinks:'true'}));
 p.repairRejectedHeadings=true;p.headingRecoveryInstructions='Source-only headings';
 const checking=acceptConditionResponse(p,initialConditionState(p),mapped);
 const done=acceptConditionResponse(p,checking,verified(false));
 assert.equal(done.phase,'completed');assert.deepEqual(done.result.unassigned,[uuid(2)]);
});

test('packed recovery crosses batches with per-entry rejection rules and deterministic restart',()=>{
 const p=plan();p.batches.push([{id:uuid(3),title:'Sleep concern',sourceWindows:['Sleep is interrupted.']}]);
 p.repairRejectedHeadings=true;p.repairRejectedLinks=true;p.packRecovery=true;p.headingRecoveryInstructions='Source only';
 let state=initialConditionState(validateConditionPlan(p));
 state=acceptConditionResponse(p,state,mapped);state=acceptConditionResponse(p,state,verified(false));
 const sleep={name:'Sleep disruption',bodySystem:'unknown',isPrimary:false,reason:'Source',entryIDs:['r1']};
 state=acceptConditionResponse(p,state,JSON.stringify({groups:[sleep],unassigned:[]}));
 state=acceptConditionResponse(p,state,JSON.stringify({decisions:[{name:sleep.name,bodySystem:'unknown',nameSupported:false,supportedEntryIDs:[],reason:'Rejected heading'}]}));
 assert.equal(state.headingRecoveries!.length,1);
 const request=nextConditionRequest(p,state)!,input=JSON.parse(request.payload.input);
 assert.deepEqual(Object.values(request.map),[uuid(2),uuid(3)]);
 assert.deepEqual(input.entries.map((e:any)=>e.rejectedHeadings),[['Pregnancy'],['Sleep disruption']]);
 assert.deepEqual(request,nextConditionRequest(p,JSON.parse(JSON.stringify(state))));
 state=acceptConditionResponse(p,state,JSON.stringify({groups:[{...sleep,entryIDs:['r1','r2']}],unassigned:[]}));
 assert.deepEqual(state.proposal!.groups[0].entryIDs,[uuid(2)]);
 assert.deepEqual(state.result.unassigned,[uuid(3)]);
 assert.deepEqual(state.result.groups,p.preserved.groups);
 state=acceptConditionResponse(p,state,JSON.stringify({decisions:[{name:sleep.name,bodySystem:'unknown',nameSupported:true,supportedEntryIDs:['r1'],reason:'Independently supported'}]}));
 assert.equal(state.phase,'completed');assert.deepEqual(state.result.groups[0],p.preserved.groups[0]);
 assert.deepEqual(state.result.groups[1].entryIDs,[uuid(2)]);
 assert.throws(()=>validateConditionPlan({...p,repairRejectedHeadings:false}));
 assert.throws(()=>validateConditionPlan({...p,packRecovery:'yes'}));
});
test('packed recovery bounds size, preserves exact evidence and exhausts each entry once',()=>{
 const p=plan();p.preserved={groups:[],unassigned:[]};p.contextEntries=[];
 p.repairRejectedHeadings=true;p.repairRejectedLinks=true;p.packRecovery=true;p.headingRecoveryInstructions='Source only';
 p.batches=Array.from({length:32},(_,i)=>[{id:uuid(i+10),sourceWindows:['Original '+i+' '+('x'.repeat(1500))]}]);
 let state=initialConditionState(p);
 for(let i=0;i<32;i++) {state=acceptConditionResponse(p,state,mapped);state=acceptConditionResponse(p,state,verified(false));}
 assert(state.headingRecoveries!.length>1 && state.headingRecoveries!.length<32);
 const seen:string[]=[];
 while(state.phase!=='completed') {
  const request=nextConditionRequest(p,JSON.parse(JSON.stringify(state)))!,input=JSON.parse(request.payload.input);
  assert(input.entries.length<=30);assert(Buffer.byteLength(JSON.stringify({entries:input.entries}))<=24000);
  for(const e of input.entries) {const id=request.map[e.id];seen.push(id);assert.deepEqual(e.sourceWindows,p.batches.flat().find(x=>x.id===id)!.sourceWindows);}
  state=acceptConditionResponse(p,state,JSON.stringify({groups:[],unassigned:Object.keys(request.map)}));
 }
 assert.equal(new Set(seen).size,32);assert.equal(state.result.unassigned.length,32);
});


test('release condition policy is frozen before hashing, idempotent, and leaves older plans unchanged',()=>{
 const old=plan();old.repairRejectedHeadings=true;old.headingRecoveryInstructions='Source only';
 assert.deepEqual(prepareConditionPlan(old),old);
 const incoming={...old,clientRevision:'condition-packed-recovery-v1'};
 const prepared=prepareConditionPlan(incoming);
 assert.equal(prepared.evidenceEncoding,'table-v1');assert.equal(prepared.packRecovery,true);assert.equal(prepared.repairRejectedLinks,true);
 assert.deepEqual(prepareConditionPlan(prepared),prepared);
 assert.equal(incoming.evidenceEncoding,undefined,'Never mutate the upload or cancellation body');
 assert.deepEqual(prepared.batches.flat(),old.batches.flat());assert.deepEqual(prepared.preserved,old.preserved);
});

test('unknown verifier ID repairs once with per-group constrained IDs and preserves checked history',()=>{
  const p=plan(),checking=acceptConditionResponse(p,initialConditionState(p),mapped);
  const raw=verified().replace('["r1"]','["r1","r8"]');
  assert.throws(()=>acceptConditionResponse(p,checking,raw));
  const repaired=repairVerificationContract(p,checking,raw)!;
  assert.equal(repaired.verificationRepair,true);assert.deepEqual(repaired.result,checking.result);
  assert.equal(checking.verificationRepair,undefined);
  const request=nextConditionRequest(p,repaired)!;
  assert.notDeepEqual(request.payload,nextConditionRequest(p,checking)!.payload,'Must not reuse the failed child response');
  const schema:any=request.payload.response_format.json_schema;
  assert.deepEqual(schema.schema.properties.decisions.properties.g0.properties.entries.items.enum,['r1']);
  assert.deepEqual(request,nextConditionRequest(p,JSON.parse(JSON.stringify(repaired))));
  assert.equal(repairVerificationContract(p,repaired,raw),null);
  assert.equal(repairVerificationContract(p,checking,verified(false)),null,'A negative judgment is not a technical failure');
  assert.equal(repairVerificationContract(p,checking,'not json'),null);
  const done=acceptConditionResponse(p,repaired,JSON.stringify({decisions:{g0:{ok:true,entries:['r1'],reason:null}}}));
  assert.equal(done.phase,'completed');assert.deepEqual(done.result.groups[0].entryIDs,[uuid(1),uuid(2)]);
  assert.throws(()=>acceptConditionResponse(p,repaired,JSON.stringify({decisions:{g0:{ok:true,entries:['r8'],reason:null}}})));
});

test('renamed legacy verifier heading is rechecked with fixed group keys, never accepted as a clinical rename',()=>{
  const p=plan(),checking=acceptConditionResponse(p,initialConditionState(p),mapped);
  const renamed=verified().replace('"name":"Pregnancy"','"name":"Pregnancy with added qualifier"');
  assert.throws(()=>acceptConditionResponse(p,checking,renamed));
  const repair=repairVerificationContract(p,checking,renamed)!;
  assert.equal(repair.verificationRepair,true);
  assert.deepEqual(repair.result,checking.result);assert.deepEqual(repair.proposal,checking.proposal);
  const schema:any=nextConditionRequest(p,repair)!.payload.response_format.json_schema;
  assert.deepEqual(schema.schema.properties.decisions.required,['g0']);
  assert.equal(schema.schema.properties.decisions.additionalProperties,false);
  assert.equal(repairVerificationContract(p,repair,renamed),null);
  const done=acceptConditionResponse(p,repair,JSON.stringify({decisions:{g0:{ok:false,entries:[],reason:'Original heading not supported.'}}}));
  assert.deepEqual(done.result.groups,p.preserved.groups);assert.deepEqual(done.result.unassigned,[uuid(2)]);
});
