import {wakeSummaryForChild} from '../api/_lib/summary-completion';
import {newSummaryExecutionPolicy,summaryConcurrency,summaryReasoning} from '../api/_lib/summary-execution-policy';
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {Pool} from 'pg';
import {validateSummaryInput,summaryPlan,summaryPayload,validatePoints,editorialRepairCandidate,applyEditorialRepair,summaryResult,SummaryInput,digest,confirmedSummaryProviderFailure} from '../api/_lib/summary-workflow';
import {submitSummary,advanceSummary,resumeSummary,summaryStatus,acknowledgeSummary,cancelSummary,cleanupSummaries,runSummary} from '../api/_lib/summary-workflow-store';
import {database,claim,settle,transaction} from '../api/_lib/ledger';
function input(kind:'record'|'practitioner'|'overview'='record'):SummaryInput{return {id:randomUUID(),contract:'summary-workflow-v1',kind,target:randomUUID(),sourceRevision:'source-1',publicationRevision:'edit-1',template:kind==='record'?'detailed':kind,evidence:[{id:'1001',text:'Declined a sweep today. May reconsider next week.'}]};}
const point={heading:'Care Plans',text:'Declined a sweep today. May reconsider next week.',citationIDs:['1001'],topic:'sweep',recipient:'unspecified',stance:'declined',subjectCitation:'1001',responseCitation:'1001',visitSection:null};
test('contracts reject unbounded, duplicate and ambiguous inputs',()=>{
 const p=input();assert.equal(validateSummaryInput(p).id,p.id);
 for(const bad of [{...p,evidence:[...p.evidence,...p.evidence]},{...p,template:'unknown'},{...p,evidence:[{id:'1001',text:'a'.repeat(24001)}]},{...p,contract:'future'}])assert.throws(()=>validateSummaryInput(bad));
});
test('all original evidence has extraction, verification and final audit; hierarchy has no forward dependency',()=>{
 const p=input();p.evidence=Array.from({length:12},(_,i)=>({id:String(1001+i),text:'a'.repeat(15000)}));
 const plan=summaryPlan(p),seen=new Set<string>();
 for(const s of plan){assert.ok(s.dependencies.every(k=>seen.has(k)));seen.add(s.key);}
 for(const e of p.evidence)for(const phase of ['draft','check','audit'])assert.ok(plan.some(s=>s.phase===phase&&s.evidenceIDs.includes(e.id)));
 assert.ok(plan.some(s=>s.phase==='merge'));assert.ok(plan.filter(s=>s.phase==='merge').every(s=>s.dependencies.length<=3));
});
test('all phases treat sources as data; citations and visit sections remain constrained',()=>{
 const p=input();p.template='visit';const s=summaryPlan(p)[0],payload=summaryPayload(p,s,{},0);
 assert.match(payload.instructions,/untrusted data/);assert.match(payload.instructions,/procedure/);
 assert.throws(()=>validatePoints(JSON.stringify({points:[point]}),p,s,{}));
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...point,visitSection:'Decided',citationIDs:['invented']}]}),p,s,{}));
 assert.equal(validatePoints(JSON.stringify({points:[{...point,visitSection:'Decided'}]}),p,s,{}).length,1);
});
test('practitioner validation requires concise fragments without removing meaningful uncertainty',()=>{
 const p=input('practitioner'),s=summaryPlan(p).at(-1)!;const b={...point,heading:'Care Plan & Interventions',text:'Sweep — declined today, possible reconsideration next week'};
 assert.equal(validatePoints(JSON.stringify({points:[b]}),p,s,{}).length,1);
 const split=validatePoints(JSON.stringify({points:[{...b,text:'Sweep — declined today; possible reconsideration next week'}]}),p,s,{});assert.deepEqual(split.map(x=>x.text),['Sweep — declined today','Sweep — possible reconsideration next week']);assert.ok(split.every(x=>JSON.stringify(x.citationIDs)===JSON.stringify(b.citationIDs)));
 for(const text of ['The patient reports that a sweep was declined.','Sweep — is declined today'])assert.throws(()=>validatePoints(JSON.stringify({points:[{...b,text}]}),p,s,{}));
});
test('final assembly deduplicates exact statements but keeps different decisions and revisions',()=>{
 const p=input(),plan=summaryPlan(p),out:any={};out['audit:0']=[point,point,{...point,text:'Sweep may be reconsidered next week.',stance:'tentative preference'}];
 const result=summaryResult(p,plan,out);assert.equal(result.points.length,2);assert.equal(result.sourceRevision,'source-1');assert.equal(result.publicationRevision,'edit-1');
});
test('publication uses the checked reconciliation of every passage audit',()=>{
 const p=input();p.evidence=[{id:'1001',text:'a'.repeat(15000)},{id:'1002',text:'b'.repeat(15000)}];
 const plan=summaryPlan(p),terminal=plan.at(-1)!;
 assert.equal(terminal.phase,'check');assert.ok(terminal.key.startsWith('final:'));
 const reachable=new Set<string>();function walk(key:string){if(reachable.has(key))return;reachable.add(key);for(const dep of plan.find(s=>s.key===key)!.dependencies)walk(dep);}walk(terminal.key);
 for(const audit of plan.filter(s=>s.phase==='audit'))assert.ok(reachable.has(audit.key));
 const corrected={...point,citationIDs:['1001','1002'],text:'Declined today; may reconsider next week.'};
 const out:any={'audit:0':[point],'audit:1':[{...point,text:'General duplicate statement.'}],[terminal.key]:[corrected]};
 const result=summaryResult(p,plan,out);assert.deepEqual(result.points,[corrected]);assert.deepEqual(result.citationIDs,['1001','1002']);
 assert.throws(()=>summaryResult(p,plan,{'audit:0':[point],'audit:1':[point]}),/unsupported_summary/);
});
test('reconciliation rejects invented citations and retains conflicting source-supported choices',()=>{
 const p=input();p.evidence=[{id:'1001',text:'a'.repeat(15000)},{id:'1002',text:'b'.repeat(15000)}];const plan=summaryPlan(p),last=plan.at(-1)!;
 const declined={...point,citationIDs:['1001']};const tentative={...point,citationIDs:['1002'],subjectCitation:'1002',responseCitation:'1002',stance:'tentative preference',text:'May reconsider next week.'};
 const out=Object.fromEntries(last.dependencies.map(k=>[k,[declined,tentative]]));
 assert.equal(validatePoints(JSON.stringify({points:[declined,tentative]}),p,last,out).length,2);
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...declined,citationIDs:['9999']}]}),p,last,out));
});
const dbURL=process.env.SUMMARY_TEST_DATABASE_URL;
test('durability, ownership, receipts, cancellation, expiry and uncertain calls in real PostgreSQL',{skip:!dbURL},async()=>{
 assert.match(dbURL!,/^postgres(?:ql)?:\/\/[^/]*127\.0\.0\.1:55439\//,'Synthetic isolated local database only');
 process.env.DATABASE_URL=dbURL;process.env.AI_DEDUPE_SECRET='synthetic-test-secret';process.env.AI_BUDGET_ID='summary-test';process.env.AI_DURABLE_ENABLED='true';process.env.AI_QUEUE_ENABLED='true';process.env.AI_SUMMARY_WORKFLOWS_ENABLED='true';process.env.AI_SUMMARY_WORKFLOW_KINDS='record,practitioner,overview';
 const setup=new Pool({connectionString:dbURL});
 try {
  for(const file of ['001_ai_ledger.sql','002_condition_workflows.sql','004_workload_types.sql','006_workflow_reasoning.sql','008_result_receipts.sql','013_summary_workflows.sql'])await setup.query(await readFile(new URL('../migrations/'+file,import.meta.url),'utf8'));
  await setup.query("INSERT INTO ai_budgets(id,limit_nusd) VALUES('summary-test',1000000000000) ON CONFLICT(id) DO UPDATE SET limit_nusd=EXCLUDED.limit_nusd");
  const owner='synthetic-'+randomUUID(),p=input();
  const submissions=await Promise.all(Array.from({length:8},()=>submitSummary(owner,p)));
  assert.ok(submissions.every(s=>s.id===p.id));assert.equal((await setup.query('SELECT count(*) FROM ai_summary_outbox WHERE workflow_id=$1',[p.id])).rows[0].count,'1');
  await assert.rejects(submitSummary('another-owner',p),/revision_conflict/);
  assert.equal(await summaryStatus('another-owner',p.id),null);
  await assert.rejects(submitSummary(owner,{...p,sourceRevision:'new'}),/revision_conflict/);
  let paidCalls=0;
  const execute=async(id:string)=>{const job=await claim(id);if(!job)return 0;paidCalls++;await settle(id,'completed',{input_tokens:10,output_tokens:50},JSON.stringify({points:[point]}));return 1;};
  // No client polling: only the queue worker advances these stages.
  for(let i=0;i<5;i++)await runSummary(p.id,execute);
  const done=await summaryStatus(owner,p.id);assert.equal(done.state,'completed');assert.equal(paidCalls,3);
  await runSummary(p.id,execute);assert.equal(paidCalls,3);
  assert.ok(done.output);await assert.rejects(acknowledgeSummary(owner,p.id,'0'.repeat(64)),/receipt_mismatch/);
  assert.equal((await setup.query('SELECT count(*) FROM ai_summary_payloads WHERE workflow_id=$1',[p.id])).rows[0].count,'1');
  await acknowledgeSummary(owner,p.id,digest(done.output));await acknowledgeSummary(owner,p.id,digest(done.output));
  assert.equal((await setup.query('SELECT count(*) FROM ai_summary_payloads WHERE workflow_id=$1',[p.id])).rows[0].count,'0');
  assert.equal((await setup.query('SELECT count(*) FROM ai_payloads p JOIN ai_summary_children c ON c.job_id=p.job_id WHERE c.workflow_id=$1',[p.id])).rows[0].count,'0');
  const beforeUpload=input();await cancelSummary(owner,beforeUpload.id);assert.equal((await submitSummary(owner,beforeUpload)).state,'cancelled');
  assert.equal((await setup.query('SELECT count(*) FROM ai_summary_payloads WHERE workflow_id=$1',[beforeUpload.id])).rows[0].count,'0');
  const cancelled=input();await submitSummary(owner,cancelled);const jobs=await advanceSummary(cancelled.id);await claim(jobs[0]);await cancelSummary(owner,cancelled.id);await settle(jobs[0],'completed',{input_tokens:10,output_tokens:50},JSON.stringify({points:[point]}));await runSummary(cancelled.id,execute);assert.equal((await summaryStatus(owner,cancelled.id)).state,'cancelled');
  assert.equal((await setup.query('SELECT count(*) FROM ai_payloads WHERE job_id=$1',[jobs[0]])).rows[0].count,'0');
  const uncertain=input();await submitSummary(owner,uncertain);const [job]=await advanceSummary(uncertain.id);await claim(job);await settle(job,'uncertain');await advanceSummary(uncertain.id);assert.equal((await summaryStatus(owner,uncertain.id)).error_code,'provider_outcome_unknown');assert.deepEqual(await advanceSummary(uncertain.id),[]);
  const lost=input();await submitSummary(owner,lost);const [savedDraft]=await advanceSummary(lost.id);await execute(savedDraft);
  const [lostCheck]=await advanceSummary(lost.id);await claim(lostCheck);await settle(lostCheck,'uncertain');await advanceSummary(lost.id);
  await setup.query("UPDATE ai_jobs SET started_at=now()-interval '11 minutes' WHERE id=$1",[lostCheck]);
  const lostCheckpoint=await summaryStatus(owner,lost.id);
  assert.equal((await resumeSummary(owner,lost.id)).state,'needs_attention');
  await Promise.all([resumeSummary(owner,lost.id,lostCheckpoint.revision),resumeSummary(owner,lost.id,lostCheckpoint.revision)]);
  assert.equal((await setup.query("SELECT attempt FROM ai_summary_steps WHERE workflow_id=$1 AND key='check:0'",[lost.id])).rows[0].attempt,1);
  assert.equal((await setup.query("SELECT state FROM ai_summary_steps WHERE workflow_id=$1 AND key='draft:0'",[lost.id])).rows[0].state,'completed');
  assert.equal((await setup.query('SELECT cost_nusd FROM ai_jobs WHERE id=$1',[lostCheck])).rows[0].cost_nusd,null);
  for(let i=0;i<4;i++)await runSummary(lost.id,execute);
  assert.equal((await summaryStatus(owner,lost.id)).state,'completed');
  const providerFailure=input();await submitSummary(owner,providerFailure);const [failedJob]=await advanceSummary(providerFailure.id);await claim(failedJob);
  await settle(failedJob,'incomplete',undefined,undefined,'synthetic-failed-response',{outputTokenLimit:100,providerStatus:'failed'});
  // Model the pre-fix stopped parent. Concurrent resume calls must not dispatch
  // duplicate children, and unknown billing must keep its reservation.
  await setup.query("UPDATE ai_summary_workflows SET state='needs_attention',error_code='provider_outcome_unknown' WHERE id=$1",[providerFailure.id]);
  const resumed=await Promise.all([resumeSummary(owner,providerFailure.id),resumeSummary(owner,providerFailure.id)]);assert.ok(resumed.every(r=>r.state==='queued'));
  await advanceSummary(providerFailure.id);
  await setup.query("UPDATE ai_summary_workflows SET retry_at=now() WHERE id=$1",[providerFailure.id]);
  const [replacement]=await advanceSummary(providerFailure.id);assert.ok(replacement);assert.notEqual(replacement,failedJob);
  assert.deepEqual(await advanceSummary(providerFailure.id),[replacement]);
  assert.equal((await setup.query('SELECT cost_nusd FROM ai_jobs WHERE id=$1',[failedJob])).rows[0].cost_nusd,null);
  for(let i=0;i<4;i++)await runSummary(providerFailure.id,execute);
  assert.equal((await summaryStatus(owner,providerFailure.id)).state,'completed');
  await acknowledgeSummary(owner,providerFailure.id,digest((await summaryStatus(owner,providerFailure.id)).output));
  assert.equal((await setup.query('SELECT count(*) FROM ai_payloads WHERE job_id=$1',[failedJob])).rows[0].count,'0');
  const explicit=input();await submitSummary(owner,explicit);const [draft]=await advanceSummary(explicit.id);await execute(draft);
  const [check]=await advanceSummary(explicit.id);await claim(check);await settle(check,'incomplete',undefined,undefined,'confirmed-failed',{outputTokenLimit:100,providerStatus:'failed'});
  await setup.query("UPDATE ai_summary_steps SET attempt=2 WHERE workflow_id=$1 AND job_id=$2",[explicit.id,check]);
  await setup.query("UPDATE ai_summary_workflows SET state='needs_attention',error_code='provider_failed' WHERE id=$1",[explicit.id]);
  const checkpoint=await summaryStatus(owner,explicit.id);
  const before=(await setup.query("SELECT output FROM ai_summary_steps WHERE workflow_id=$1 AND key='draft:0'",[explicit.id])).rows[0].output;
  await Promise.all([resumeSummary(owner,explicit.id,checkpoint.revision),resumeSummary(owner,explicit.id,checkpoint.revision)]);
  const retried=(await setup.query("SELECT attempt FROM ai_summary_steps WHERE workflow_id=$1 AND key='check:0'",[explicit.id])).rows[0];assert.equal(retried.attempt,3);
  assert.deepEqual((await setup.query("SELECT output FROM ai_summary_steps WHERE workflow_id=$1 AND key='draft:0'",[explicit.id])).rows[0].output,before);
  const [newCheck]=await advanceSummary(explicit.id);assert.notEqual(newCheck,check);assert.notEqual(newCheck,draft);
  for(let i=0;i<4;i++)await runSummary(explicit.id,execute);
  const explicitDone=await summaryStatus(owner,explicit.id);assert.equal(explicitDone.state,'completed');await acknowledgeSummary(owner,explicit.id,digest(explicitDone.output));
  const expired=input();await submitSummary(owner,expired);await advanceSummary(expired.id);await setup.query("UPDATE ai_summary_workflows SET expires_at=now()-interval '1 second' WHERE id=$1",[expired.id]);await cleanupSummaries();assert.equal((await summaryStatus(owner,expired.id)).state,'expired');
  const attention=input();await submitSummary(owner,attention);const [bad]=await advanceSummary(attention.id);await claim(bad);await settle(bad,'completed',{input_tokens:10,output_tokens:20},'{}');await advanceSummary(attention.id);
  const [repair]=await advanceSummary(attention.id);assert.notEqual(repair,bad);await claim(repair);await settle(repair,'completed',{input_tokens:10,output_tokens:20},JSON.stringify({points:[point]}));
  for(let i=0;i<4;i++)await runSummary(attention.id,execute);const repaired=await summaryStatus(owner,attention.id);assert.equal(repaired.state,'completed');
  await acknowledgeSummary(owner,attention.id,digest(repaired.output));assert.equal((await setup.query('SELECT count(*) FROM ai_payloads WHERE job_id=ANY($1::uuid[])',[[bad,repair]])).rows[0].count,'0');
  // PostgreSQL preserves microseconds that JS Date drops. A retry must never
  // treat its own row as a newer replacement and purge completed work.
  const precise=input();await submitSummary(owner,precise);
  await setup.query("UPDATE ai_summary_workflows SET created_at='2026-11-19 15:54:00.123456+00' WHERE id=$1",[precise.id]);
  assert.equal((await resumeSummary(owner,precise.id,(await summaryStatus(owner,precise.id)).revision)).state,'queued');
  assert.equal((await setup.query('SELECT count(*) FROM ai_summary_payloads WHERE workflow_id=$1',[precise.id])).rows[0].count,'1');
  const stoppedOld=input();await submitSummary(owner,stoppedOld);
  await setup.query("UPDATE ai_summary_workflows SET state='needs_attention',error_code='provider_failed' WHERE id=$1",[stoppedOld.id]);
  const current=input();current.target=stoppedOld.target;await submitSummary(owner,current);
  assert.equal((await resumeSummary(owner,stoppedOld.id,(await summaryStatus(owner,stoppedOld.id)).revision)).state,'superseded');
  assert.equal((await summaryStatus(owner,current.id)).state,'queued');
  const [older,newer]=[input(),input()];newer.target=older.target;await submitSummary(owner,older);await submitSummary(owner,newer);assert.equal((await summaryStatus(owner,older.id)).state,'superseded');
  // New scheduling policy is frozen per workflow, including after flag rollback.
  process.env.AI_SUMMARY_PARALLEL_V2='true';
  const fast=input('practitioner');fast.evidence=Array.from({length:12},(_,i)=>({id:String(1001+i),text:'a'.repeat(15000)}));
  const speedOwner='speed-'+randomUUID();await submitSummary(speedOwner,fast);
  delete process.env.AI_SUMMARY_PARALLEL_V2;
  assert.equal((await setup.query('SELECT execution_policy FROM ai_summary_workflows WHERE id=$1',[fast.id])).rows[0].execution_policy,'parallel-six-v2');
  // Simulate an older coordinator: its entire transaction must roll back before
  // paid inference, while cancellation and receipt operations remain available.
  await assert.rejects(setup.query("UPDATE ai_summary_workflows SET state='running',calls=1 WHERE id=$1",[fast.id]),/summary_execution_policy_mismatch/);
  assert.equal((await summaryStatus(speedOwner,fast.id)).calls,0);
  const fastChildren=await advanceSummary(fast.id);assert.equal(fastChildren.length,6);
  // Provider completion wakes a leased delayed check without creating/replacing children.
  await assert.rejects(setup.query("UPDATE ai_summary_outbox SET lease_until=now()+interval '60 seconds' WHERE workflow_id=$1",[fast.id]),/summary_dispatch_policy_mismatch/);
  await transaction(async tx=>{
   await tx.query("SELECT set_config('collectivecare.summary_dispatch','v2',true)");
   await tx.query("UPDATE ai_summary_outbox SET available_at=now()+interval '30 seconds',lease_until=now()+interval '60 seconds' WHERE workflow_id=$1",[fast.id]);
  });
  assert.equal(await wakeSummaryForChild(fastChildren[0],setup),true);
  assert.equal(await wakeSummaryForChild(fastChildren[0],setup),true);
  const outbox=(await setup.query('SELECT lease_until,available_at<=now() due FROM ai_summary_outbox WHERE workflow_id=$1',[fast.id])).rows;
  assert.equal(outbox.length,1);assert.equal(outbox[0].lease_until,null);assert.equal(outbox[0].due,true);
  assert.equal((await setup.query('SELECT calls FROM ai_summary_workflows WHERE id=$1',[fast.id])).rows[0].calls,6);
  assert.equal(await wakeSummaryForChild(randomUUID(),setup),false);
  // Cancellation cannot be revived by a late completion callback.
  await cancelSummary(speedOwner,fast.id);assert.equal(await wakeSummaryForChild(fastChildren[0],setup),false);
  const baseline=input('practitioner');baseline.evidence=fast.evidence;
  await submitSummary(speedOwner,baseline);assert.equal((await advanceSummary(baseline.id)).length,3);
  await cancelSummary(speedOwner,baseline.id);
  // Six-way admission degrades to the funded capacity instead of failing a run.
  const reserve=Number((await setup.query('SELECT reserve_nusd FROM ai_jobs WHERE id=$1',[fastChildren[0]])).rows[0].reserve_nusd);
  const budget='bounded-'+randomUUID();await setup.query('INSERT INTO ai_budgets(id,limit_nusd) VALUES($1,$2)',[budget,3*reserve]);
  process.env.AI_BUDGET_ID=budget;process.env.AI_SUMMARY_PARALLEL_V2='true';
  const bounded=input('practitioner');bounded.evidence=fast.evidence;await submitSummary(speedOwner,bounded);
  process.env.AI_BUDGET_ID='summary-test';delete process.env.AI_SUMMARY_PARALLEL_V2;
  const admitted=await advanceSummary(bounded.id);assert.equal(admitted.length,3);
  assert.equal((await summaryStatus(speedOwner,bounded.id)).state,'running');
  assert.equal((await summaryStatus(speedOwner,bounded.id)).calls,3);
  for(const child of admitted){await claim(child);await settle(child,'completed',{input_tokens:0,output_tokens:0},JSON.stringify({points:[]}));}
  const next=await advanceSummary(bounded.id);assert.equal(next.length,3);
  assert.equal((await summaryStatus(speedOwner,bounded.id)).state,'running');
  await cancelSummary(speedOwner,bounded.id);
  // A genuinely exhausted budget with no pending reservations still surfaces.
  const exhausted=input('practitioner');process.env.AI_BUDGET_ID=budget;
  await setup.query('UPDATE ai_budgets SET limit_nusd=used_nusd+reserved_nusd WHERE id=$1',[budget]);
  await submitSummary(speedOwner,exhausted);process.env.AI_BUDGET_ID='summary-test';
  await advanceSummary(exhausted.id);
  assert.equal((await summaryStatus(speedOwner,exhausted.id)).state,'needs_attention');
  process.env.AI_SUMMARY_PARALLEL_V2='true';process.env.AI_SUMMARY_MERGE_LOW='true';
  const pinned=input('practitioner');pinned.evidence=fast.evidence;const pinnedOwner='pinned-'+randomUUID();
  await submitSummary(pinnedOwner,pinned);delete process.env.AI_SUMMARY_PARALLEL_V2;delete process.env.AI_SUMMARY_MERGE_LOW;
  const finish=async(id:string)=>{
   const job=await claim(id);if(!job)return 0;
   const ref=(job.payload.response_format.json_schema as any).schema.properties.points.items.properties.citationIDs.items.enum[0];
   await settle(id,'completed',{input_tokens:0,output_tokens:0},JSON.stringify({points:[{...point,heading:'Care Plan & Interventions',text:'Sweep — declined today',citationIDs:[ref],subjectCitation:ref,responseCitation:ref}]}));return 1;
  };
  for(let i=0;i<30&&(await summaryStatus(pinnedOwner,pinned.id)).state!=='completed';i++)await runSummary(pinned.id,finish);
  assert.equal((await summaryStatus(pinnedOwner,pinned.id)).state,'completed');
  const efforts=(await setup.query('SELECT s.key,j.reasoning_effort FROM ai_summary_steps s JOIN ai_jobs j ON j.id=s.job_id WHERE s.workflow_id=$1',[pinned.id])).rows;
  assert.ok(efforts.some(r=>r.key.startsWith('merge:')));
  assert.ok(efforts.every(r=>r.reasoning_effort===(r.key.startsWith('merge:')&&!r.key.endsWith(':check')?'low':'medium')));
  await acknowledgeSummary(pinnedOwner,pinned.id,digest((await summaryStatus(pinnedOwner,pinned.id)).output));


 } finally {await setup.end();await database().end();}
});

test('PDF separators and blank sentences do not reject an otherwise valid saved request',()=>{
 const p=input();p.evidence=[{id:'1001',text:'\n\f\r\t '},{id:'1002',text:'Declined a sweep today.'},{id:'1003',text:'\n'},{id:'1004',text:'May reconsider next week.'}];
 const validated=validateSummaryInput(p);
 assert.deepEqual(validated.evidence,p.evidence.filter(e=>e.text.trim()));
 assert.deepEqual(validated.evidence.map(e=>e.id),['1002','1004']);
 assert.deepEqual(validateSummaryInput(validated),validated);
 const plan=summaryPlan(validated);assert.ok(plan.every(s=>s.evidenceIDs.every(id=>['1002','1004'].includes(id))));
 assert.throws(()=>validateSummaryInput({...p,evidence:[{id:'1001',text:'\n\f'}]}),/invalid_summary_input/);
 assert.throws(()=>validateSummaryInput({...p,evidence:[...p.evidence,{id:'1001',text:'Other'}]}),/invalid_summary_input/);
 assert.throws(()=>validateSummaryInput({...p,evidence:[{id:'1001',text:null}]}),/invalid_summary_input/);
});

test('confirmed generation failures can retry without treating unknown charges as success',()=>{
 const failed={job_state:'uncertain',provider_id:'synthetic-response',result:{diagnostics:{providerStatus:'failed'}}};
 assert.equal(confirmedSummaryProviderFailure(failed),true);
 assert.equal(confirmedSummaryProviderFailure({...failed,job_state:'incomplete'}),true);
 for(const status of ['completed','in_progress','queued','cancelled','incomplete',undefined])assert.equal(confirmedSummaryProviderFailure({...failed,result:{diagnostics:{providerStatus:status}}}),false);
 assert.equal(confirmedSummaryProviderFailure({...failed,provider_id:undefined}),false);
 assert.equal(confirmedSummaryProviderFailure({...failed,job_state:'running'}),false);
});

test('final record recap rejects paragraph prose rather than silently truncating clinical meaning',()=>{
 for(const template of ['visit','detailed'] as const){
  const p=input();p.template=template;
  const plan=summaryPlan(p),last=plan.at(-1)!;
  const candidate={...point,visitSection:template==='visit'?'Decided':null};
  const outputs=Object.fromEntries(last.dependencies.map(key=>[key,[candidate]]));
  const read=(text:string)=>validatePoints(JSON.stringify({points:[{...candidate,text}]}),p,last,outputs);
  const concise='Declined membrane sweep today; may reconsider next week.';
  assert.equal(read(concise)[0].text,concise);
  assert.throws(()=>read('Declined a membrane sweep today and deferred reconsideration until next week, with no commitment to have one then or to repeat it. A sweep is optional and requires examination.'),/invalid_summary_output/);
  for(const text of ['The patient reports back pain.','The mother expresses concern about labor.','The examination revealed a low baby.','Visit on the 19th; month not specified.'])assert.throws(()=>read(text),/invalid_summary_output/);
  // The evidence and working draft remain complete for the coverage audit.
  const long='Discussed '+Array(35).fill('source').join(' ');
  assert.equal(validatePoints(JSON.stringify({points:[{...candidate,text:long}]}),p,plan[0],{})[0].text,long);
 }
});
test('compact publication preserves tentative newborn care, declines, deferred testing and booked actions',()=>{
 const p=input();p.template='visit';p.evidence=[
  {id:'1001',text:'I think we are okay with vitamin K for the newborn. When is it given?'},
  {id:'1002',text:'I do not want castor oil now.'},
  {id:'1003',text:'No sweep today. Maybe consider it next week.'},
  {id:'1004',text:'Decide about bilirubin testing after assessing feeding and jaundice.'},
  {id:'1005',text:'Appointment with Nicole on the 19th at 10 a.m.'}
 ];
 const texts=['Newborn vitamin K: tentatively okay; asked about timing after birth.','Declined castor oil.','Declined membrane sweep today; may reconsider next week.','Bilirubin screening: decide after birth, based on feeding and jaundice.','Visit with Nicole: 19th, 10 a.m.'];
 const candidates=texts.map((text,i)=>({...point,text,citationIDs:[String(1001+i)],subjectCitation:String(1001+i),responseCitation:String(1001+i),visitSection:i===0?'Discussed':i===4?'Next steps':'Decided'}));
 const plan=summaryPlan(p),last=plan.at(-1)!;
 const outputs=Object.fromEntries(last.dependencies.map(key=>[key,candidates]));
 const checked=validatePoints(JSON.stringify({points:candidates}),p,last,outputs);
 assert.deepEqual(checked,candidates);
 assert.deepEqual(summaryResult(p,plan,{...outputs,[last.key]:checked}).points,candidates);
});

// A word ceiling per bullet alone still allows a transcript-shaped inventory.
test('final recap has a whole-summary budget as well as a per-bullet limit',()=>{
 const p=input(),last=summaryPlan(p).at(-1)!;
 const candidate={...point,text:'Brief low-back discomfort while sitting; easing spontaneously.'};
 const outputs=Object.fromEntries(last.dependencies.map(key=>[key,[candidate]]));
 assert.throws(()=>validatePoints(JSON.stringify({points:Array(30).fill(candidate)}),p,last,outputs),/invalid_summary_output/);
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...candidate,text:Array(19).fill('word').join(' ')}]}),p,last,outputs),/invalid_summary_output/);
});

test('publication editor is not instructed to re-expand the full evidence inventory',()=>{
 const p=input();p.evidence=[{id:'1001',text:'a'.repeat(15000)},{id:'1002',text:'b'.repeat(15000)}];
 const last=summaryPlan(p).at(-1)!;const outputs=Object.fromEntries(last.dependencies.map(k=>[k,[point]]));
 const payload=summaryPayload(p,last,outputs,1),body=JSON.parse(payload.input);
 assert.deepEqual(body.mainDraft,[point]);assert.equal(body.supportingEvidence.length,last.dependencies.length-1);
 assert.equal(body.candidates,undefined);
 assert.doesNotMatch(payload.instructions,/Return the full checked points|retain every distinct detail|Correct unsupported claims and omissions/);
 assert.match(payload.instructions,/200 total words/);
});

test('practitioner final editing selects a compact handoff without record-template instructions',()=>{
 const p=input('practitioner');p.structuredLabs=true;const plan=summaryPlan(p),last=plan.at(-1)!;
 const fact={...point,heading:'Care Plan & Interventions',text:'Vitamin K — tentative preference for newborn injection',visitSection:null};
 const outputs=Object.fromEntries(last.dependencies.map(k=>[k,[fact]]));
 const payload=summaryPayload(p,last,outputs,1),body=JSON.parse(payload.input);
 assert.deepEqual(body.mainDraft,[fact]);assert.equal(body.candidates,undefined);
 assert.doesNotMatch(payload.instructions,/200/);assert.match(payload.instructions,/No fixed total-word or page target/);assert.match(payload.instructions,/Medication names without dose/);
 assert.match(payload.instructions,/Structured lab results are rendered separately/);
 assert.doesNotMatch(payload.instructions,/For Visit:|Return the full checked points/);
 assert.deepEqual(validatePoints(JSON.stringify({points:[fact]}),p,last,outputs),[fact]);
 const expanded=Array.from({length:30},(_,i)=>({...fact,text:`Concern ${i} — distinct relevant concern w/ meaningful ongoing clinical follow-up`}));
 assert.equal(validatePoints(JSON.stringify({points:expanded}),p,last,outputs).length,30);
 // Working coverage drafts retain the facts for later editorial selection.
 assert.equal(validatePoints(JSON.stringify({points:Array(30).fill(fact)}),p,plan[0],{}).length,30);
});

test('practitioner coverage drafts may retain source narration while publication rejects it',()=>{
 const p=input('practitioner'),plan=summaryPlan(p);
 const b={...point,heading:'Care Plan & Interventions',text:'The patient reports that a sweep was declined today and may be reconsidered next week.'};
 assert.deepEqual(validatePoints(JSON.stringify({points:[b]}),p,plan[0],{}),[b]);
 assert.throws(()=>validatePoints(JSON.stringify({points:[b]}),p,plan.at(-1)!,{}),/invalid_summary_output/);
});

test('output-limit recovery requires a terminal provider receipt, never an unknown outcome',async()=>{
 const {confirmedSummaryOutputLimit}=await import('../api/_lib/summary-workflow');
 const receipt={job_state:'incomplete',provider_id:'synthetic',result:{diagnostics:{providerStatus:'incomplete',incompleteReason:'max_output_tokens'}}};
 assert.equal(confirmedSummaryOutputLimit(receipt),true);
 for(const state of ['running','uncertain','completed'])assert.equal(confirmedSummaryOutputLimit({...receipt,job_state:state}),false);
 assert.equal(confirmedSummaryOutputLimit({...receipt,provider_id:undefined}),false);
 for(const reason of ['content_filter','other',undefined])assert.equal(confirmedSummaryOutputLimit({...receipt,result:{diagnostics:{providerStatus:'incomplete',incompleteReason:reason}}}),false);
});

test('short handoff qualifiers can use remaining bullet words without failing a second smaller limit',()=>{
 const p=input();p.kind='practitioner';p.template='practitioner';const plan=summaryPlan(p);
 const text='Follow-up — booked for next Tuesday morning with the care team to discuss remaining questions';
 const b={...point,heading:'Care Coordination Summary',text};
 assert.equal(validatePoints(JSON.stringify({points:[b]}),p,plan.at(-1)!,{}).length,1);
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...b,text:text+' and additional treatment options'}]}),p,plan.at(-1)!,{}),/invalid_summary_output/);
});

test('compact practitioner plan covers every source with fewer bounded stages',()=>{
 const p=input('practitioner');p.evidence=Array.from({length:48},(_,i)=>({id:String(i),text:'x'.repeat(18000)}));
 const old=summaryPlan(p);p.pipeline='compact-v2';const plan=summaryPlan(p);const seen=new Set<string>();
 for(const step of plan){assert.ok(step.dependencies.every(k=>seen.has(k)));assert.ok(step.dependencies.length<=8);seen.add(step.key);}
 for(const e of p.evidence)for(const phase of ['draft','check','audit'])assert.ok(plan.some(s=>s.phase===phase&&s.evidenceIDs.includes(e.id)));
 assert.ok(plan.length<old.length/3);assert.equal(plan.at(-1)?.key,'final:publish:check');
 console.log('SYNTHETIC_PLAN_COUNTS '+JSON.stringify({legacy:old.length,compact:plan.length}));
});
test('bullet dates come only from cited evidence metadata',()=>{
 const p=input('practitioner');p.evidence[0].timelineLabel='Record: 20 Nov 2026';
 p.evidence.push({id:'uncited',text:'Unrelated',timelineLabel:'Date: 2020-01-01'});
 const plan=summaryPlan(p),terminal=plan.at(-1)!;
 const result=summaryResult(p,plan,{[terminal.key]:[{...point,heading:'Clinical Snapshot',text:'Sweep — declined today'}]});
 assert.deepEqual(result.bulletDates,[{text:'Sweep — declined today',labels:['Record: 20 Nov 2026']}]);
});

test('essential clinical context survives every practitioner phase, without patient-specific assumptions',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';
 for(const step of summaryPlan(p)) {
  const instructions=summaryPayload(p,step,{},0).instructions;
  assert.match(instructions,/Lead Clinical Snapshot with documented context/);
  assert.match(instructions,/Abnormal-only filtering applies to laboratory and investigation results, not essential clinical context/);
  assert.match(instructions,/Never assume a time-sensitive state remains current/);
  assert.match(instructions,/preserve it through final selection/);
 }
 const r=input('record');
 assert.doesNotMatch(summaryPayload(r,summaryPlan(r)[0],{},0).instructions,/ESSENTIAL CLINICAL CONTEXT/);
});

test('faster concurrency is opt-in, practitioner-only, and unknown versions stay conservative',()=>{
 process.env.AI_SUMMARY_PARALLEL_V2='true';
 assert.equal(newSummaryExecutionPolicy('practitioner'),'parallel-six-v2');
 assert.equal(newSummaryExecutionPolicy('record'),'baseline-three-v1');
 assert.equal(summaryConcurrency('parallel-six-v2'),6);
 assert.equal(summaryConcurrency('future'),3);
 delete process.env.AI_SUMMARY_PARALLEL_V2;
 assert.equal(newSummaryExecutionPolicy('practitioner'),'baseline-three-v2');
});

test('lower reasoning is pinned and limited to intermediate merges before the source audits',()=>{
 process.env.AI_SUMMARY_PARALLEL_V2='true';process.env.AI_SUMMARY_MERGE_LOW='true';
 const policy=newSummaryExecutionPolicy('practitioner');assert.equal(policy,'parallel-six-low-merge-v2');assert.equal(summaryConcurrency(policy),6);
 assert.equal(newSummaryExecutionPolicy('record'),'baseline-three-v1');
 assert.equal(summaryReasoning(policy,{phase:'merge',key:'merge:0:0'}),'low');
 for(const step of [{phase:'draft',key:'draft:0'},{phase:'check',key:'check:0'},{phase:'audit',key:'audit:0'},{phase:'merge',key:'final:0:0'},{phase:'check',key:'final:publish:check'}])assert.equal(summaryReasoning(policy,step),'medium');
 for(const old of ['baseline-three-v1','parallel-six-v2','unknown'])assert.equal(summaryReasoning(old,{phase:'merge',key:'merge:0:0'}),'medium');
 delete process.env.AI_SUMMARY_PARALLEL_V2;delete process.env.AI_SUMMARY_MERGE_LOW;
});


test('practitioner section purposes preserve history and distinct perspectives through every phase',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';p.evidence=Array.from({length:12},(_,i)=>({id:String(i),text:'source '.repeat(3000)}));
 const phases=new Set<string>();
 for(const step of summaryPlan(p)){
  phases.add(step.phase);const instructions=summaryPayload(p,step,{},0).instructions;
  assert.match(instructions,/SECTION PURPOSE AND COVERAGE/);
  assert.match(instructions,/Preserve each distinct relevant milestone even when it is no longer an active problem/);
  assert.match(instructions,/Order dated historical milestones chronologically/);
  assert.match(instructions,/allow a condition in multiple sections when each adds a distinct perspective/);
  assert.match(instructions,/expressed patient priorities or practical constraints/);
  assert.match(instructions,/retain explicitly planned investigations as plans/);
 }
 assert.deepEqual([...phases].sort(),['audit','check','draft','merge']);
 const record=input('record');assert.doesNotMatch(summaryPayload(record,summaryPlan(record)[0],{},0).instructions,/SECTION PURPOSE AND COVERAGE/);
});


test('new publication responses account for audited history while old saved responses remain readable',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';const step=summaryPlan(p).at(-1)!;
 const first={...point,heading:'Comprehensive Health History',text:'Appendectomy — 2017, uncomplicated recovery'};
 const second={...point,heading:'Comprehensive Health History',text:'Pregnancy — 2012, full-term vaginal delivery'};
 const outputs:any={[step.dependencies[0]]:[first,second]};
 const payload=summaryPayload(p,step,outputs,0);const content=JSON.parse(payload.input);
 assert.deepEqual(content.requiredHistory.map((h:any)=>h.id),['history:0','history:1']);
 assert.match(payload.instructions,/Preserve every listed historical milestone/);
 const good=[{...first,historyIDs:['history:0']},{...second,historyIDs:['history:1']}];
 assert.equal(validatePoints(JSON.stringify({points:good}),p,step,outputs).length,2);
 for(const bad of [good.slice(0,1),[{...first,historyIDs:['history:9']},good[1]],[{...first,heading:'Clinical Snapshot',historyIDs:['history:0']},good[1]]])assert.throws(()=>validatePoints(JSON.stringify({points:bad}),p,step,outputs));
 assert.equal(validatePoints(JSON.stringify({points:[first,second]}),p,step,outputs).length,2);
 const split=validatePoints(JSON.stringify({points:[{...good[0],text:'Appendectomy — 2017; uncomplicated recovery'},good[1]]}),p,step,outputs);
 assert.equal(split.length,3);assert.deepEqual(split[1].historyIDs,[]);
});

test('coordination checklist prevents final editing from dropping named care relationships',()=>{
 const p=input('practitioner'),step=summaryPlan(p).at(-1)!;
 const first={...point,heading:'Care Coordination Summary',text:'Dr. Lee — treating neurologist'};
 const second={...point,heading:'Care Coordination Summary',text:'Physiotherapy — referral contemplated'};
 const outputs=Object.fromEntries(step.dependencies.map(key=>[key,[first,second]]));
 const payload=summaryPayload(p,step,outputs,0),content=JSON.parse(payload.input);
 assert.equal(content.requiredCoordination.length,2);
 assert.match(payload.instructions,/Include a named provider even without an agreed new action/);
 const good=[{...first,coordinationIDs:['coordination:0']},{...second,coordinationIDs:['coordination:1']}];
 assert.equal(validatePoints(JSON.stringify({points:good}),p,step,outputs).length,2);
 assert.throws(()=>validatePoints(JSON.stringify({points:good.slice(0,1)}),p,step,outputs));
});
test('point-specific time overrides grouped evidence timeline and preserves semantic role',()=>{
 const p=input('practitioner');p.evidence[0].timelineLabel='Record: 2026-11-20';
 const plan=summaryPlan(p),terminal=plan.at(-1)!;
 const temporal={role:'ongoing' as const,start:'2024-09-06',end:null,approximate:false,sourceQuote:'Breastfeeding Sep 6, 2024',citationIDs:[p.evidence[0].id]};
 const b={...point,heading:'Comprehensive Health History',text:'Breastfeeding — ongoing',temporal};
 const result=summaryResult(p,plan,{[terminal.key]:[b]});
 assert.deepEqual(result.bulletDates[0].labels,['Date: 2024-09-06']);assert.equal(result.bulletDates[0].temporal?.role,'ongoing');
 const unknown={role:'unknown' as const,start:null,end:null,approximate:false,sourceQuote:null,citationIDs:[]};
 assert.deepEqual(summaryResult(p,plan,{[terminal.key]:[{...b,temporal:unknown}]}).bulletDates[0].labels,['Record: 2026-11-20']);
});

test('identical wording at distinct supported event dates is not deduplicated',()=>{
 const p=input('practitioner'),plan=summaryPlan(p),terminal=plan.at(-1)!;
 const first={...point,heading:'Comprehensive Health History',text:'Back pain — recurrent',temporal:{role:'event' as const,start:'2024',end:null,approximate:false,sourceQuote:'Back pain 2024',citationIDs:[p.evidence[0].id]}};
 const second={...first,temporal:{...first.temporal,start:'2025'}};
 assert.equal(summaryResult(p,plan,{[terminal.key]:[first,second]}).points.length,2);
});

test('unfinished legacy stages do not suddenly require semantic metadata',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';const plan=summaryPlan(p),check=plan.find(s=>s.key==='check:0')!;
 const legacy=summaryPayload(p,check,{'draft:0':[point]},0);
 const schema:any=legacy.response_format.json_schema;
 assert.equal(schema.schema.properties.points.items.properties.temporal,undefined);
 assert.ok(!legacy.instructions.includes('POINT-SPECIFIC TIME'));
 const fresh:any=summaryPayload(p,plan[0],{},0).response_format.json_schema;
 assert.ok(fresh.schema.properties.points.items.properties.temporal);
});

test('invalid date metadata does not reject grounded points or bypass citation checks',()=>{
 const p=input('practitioner'),s=summaryPlan(p)[0];
 const b={...point,heading:'Care Plan & Interventions',temporal:{role:'event',start:'2024',end:null,approximate:false,sourceQuote:'Unsupported 2024 date',citationIDs:['1001']}};
 const [result]=validatePoints(JSON.stringify({points:[b]}),p,s,{});
 assert.equal(result.text,b.text);assert.deepEqual(result.citationIDs,b.citationIDs);
 assert.equal(result.temporal?.role,'unknown');assert.equal(result.temporal?.start,null);
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...b,citationIDs:['invented']}]}),p,s,{}));
});

test('explicit subject and response citations reconcile only within the allowed source set',()=>{
 const p=input('practitioner');p.evidence.push({id:'1002',text:'May reconsider next week.'});const s=summaryPlan(p)[0];
 const b={...point,heading:'Care Plan & Interventions',responseCitation:'1002'};
 const [result]=validatePoints(JSON.stringify({points:[b]}),p,s,{});
 assert.deepEqual(result.citationIDs,['1001','1002']);assert.equal(result.text,b.text);
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...b,responseCitation:'invented'}]}),p,s,{}));
 assert.throws(()=>validatePoints(JSON.stringify({points:[b]}),p,{...s,evidenceIDs:['1001']},{}));
});

test('source audits and publication protect history independently of lossy merged drafts',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';
 p.evidence=[{id:'1001',text:'Appendectomy in 2012.'},{id:'1002',text:'Dr Smith previously treated headaches.'}];
 const plan=summaryPlan(p),audit={...plan.find(s=>s.phase==='audit')!,dependencies:['merged']},final=plan.at(-1)!;
 const history={...point,heading:'Comprehensive Health History',text:'Appendectomy — 2012',topic:'Appendectomy',stance:null};
 const provider={...point,heading:'Care Coordination Summary',text:'Dr Smith — previous headache care',citationIDs:['1002'],subjectCitation:'1002',responseCitation:null,stance:null};
 const checked={'check:0':[history,provider],[audit.dependencies[0]]:[]};
 const auditInput=JSON.parse(summaryPayload(p,audit,checked,0).input);
 assert.equal(auditInput.requiredHistory.length,1);assert.equal(auditInput.requiredCoordination.length,1);
 const restored=[{...history,historyIDs:['history:0'],coordinationIDs:[]},{...provider,historyIDs:[],coordinationIDs:['coordination:0']}];
 assert.throws(()=>validatePoints(JSON.stringify({points:[restored[1]]}),p,audit,checked));
 assert.equal(validatePoints(JSON.stringify({points:restored}),p,audit,checked).length,2);
 const audited={...checked,[audit.key]:restored};
 // A multi-stage merge can erase the whole section. Its audited inventory survives.
 const publication={...final,dependencies:['lost-merge']};
 const outputs={...audited,'lost-merge':[]};
 const body=JSON.parse(summaryPayload(p,publication,outputs,0).input);
 assert.equal(body.mainDraft.length,0);assert.equal(body.requiredHistory.length,1);
 assert.throws(()=>validatePoints(JSON.stringify({points:[]}),p,publication,outputs));
 assert.throws(()=>validatePoints(JSON.stringify({points:[restored[1]]}),p,publication,outputs));
 assert.equal(validatePoints(JSON.stringify({points:restored}),p,publication,outputs).length,2);
 // Inventory IDs must not change with database row order.
 assert.deepEqual(JSON.parse(summaryPayload(p,publication,Object.fromEntries(Object.entries(outputs).reverse()),0).input).requiredHistory,body.requiredHistory);
});

test('a source-checked milestone may split across supported audit bullets',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';const audit={...summaryPlan(p).find(s=>s.phase==='audit')!,dependencies:['merged']};
 const original={...point,heading:'Comprehensive Health History',text:'Past surgery — procedure and recovery',stance:null};
 const outputs={'check:0':[original],merged:[]};
 const split=[{...original,text:'Past surgery — procedure',historyIDs:['history:0'],coordinationIDs:[]},{...original,text:'Recovery — postoperative course',historyIDs:['history:0'],coordinationIDs:[]}];
 assert.equal(validatePoints(JSON.stringify({points:split}),p,audit,outputs).length,2);
 assert.throws(()=>validatePoints(JSON.stringify({points:split.map(b=>({...b,historyIDs:[]}))}),p,audit,outputs));
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...split[0],heading:'Clinical Snapshot'}]}),p,audit,outputs));
 const extra=validatePoints(JSON.stringify({points:[{...split[0],heading:'Clinical Snapshot'},split[1]]}),p,audit,outputs);
 assert.deepEqual(extra[0].historyIDs,[]);assert.equal(extra[0].text,split[0].text);
});

test('duplicate provider coverage annotation in another section is removed only when already represented',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';const audit={...summaryPlan(p).find(s=>s.phase==='audit')!,dependencies:['merged']};
 const provider={...point,heading:'Care Coordination Summary',text:'Dr Lee — treating neurologist',stance:null};
 const outputs={'check:0':[provider],merged:[]};
 const good={...provider,historyIDs:[],coordinationIDs:['coordination:0']};const extra={...good,heading:'Care Plan & Interventions',text:'Migraine — current treatment'};
 const result=validatePoints(JSON.stringify({points:[good,extra]}),p,audit,outputs);
 assert.deepEqual(result[0].coordinationIDs,['coordination:0']);assert.deepEqual(result[1].coordinationIDs,[]);assert.equal(result[1].text,extra.text);
 assert.throws(()=>validatePoints(JSON.stringify({points:[extra]}),p,audit,outputs));
});

test('publication never exposes colliding coverage IDs from earlier audit batches',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';p.evidence.push({id:'1002',text:'Second historical event.'});
 const a={...point,heading:'Comprehensive Health History',text:'First surgery — 2012',historyIDs:['history:0'],coordinationIDs:[]};
 const b={...a,text:'Second surgery — 2015',citationIDs:['1002'],subjectCitation:null,responseCitation:null};
 const final=summaryPlan(p).at(-1)!;
 const outputs={'audit:0':[a],'audit:1':[b],[final.dependencies[0]]:[a,b]};
 const body=JSON.parse(summaryPayload(p,final,outputs,0).input);
 assert.deepEqual(body.requiredHistory.map((x:any)=>x.id),['history:0','history:1']);
 for(const point of [...body.mainDraft,...body.requiredHistory.map((x:any)=>x.point)]){
  assert.equal(point.historyIDs,undefined);assert.equal(point.coordinationIDs,undefined);
 }
 assert.deepEqual(outputs['audit:1'][0].historyIDs,['history:0']);
});

test('long practitioner publication has room for history and providers together',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';const step=summaryPlan(p).at(-1)!;
 const b={...point,heading:'Comprehensive Health History',text:'Surgery — prior procedure',stance:null};
 const outputs={[step.dependencies[0]]:[b]};
 const payload:any=summaryPayload(p,step,outputs,0);
 assert.equal(payload.response_format.json_schema.schema.properties.points.maxItems,160);
 assert.equal(validatePoints(JSON.stringify({points:Array.from({length:100},()=>b)}),p,step,outputs).length,100);
 assert.throws(()=>validatePoints(JSON.stringify({points:Array.from({length:161},()=>b)}),p,step,outputs));
 const draft=summaryPlan(p)[0];assert.equal((summaryPayload(p,draft,{},0).response_format.json_schema as any).schema.properties.points.maxItems,80);
});

test('editorial recovery repairs only rejected wording and retains accepted content and metadata',()=>{
 const p=input('practitioner');p.pipeline='compact-v2';const step=summaryPlan(p).at(-1)!;
 const good={...point,heading:'Clinical Snapshot',text:'Back pain — intermittent',stance:null,historyIDs:[],coordinationIDs:[]};
 const bad={...good,heading:'Comprehensive Health History',text:'Back pain — symptoms are intermittent',historyIDs:['history:0'],coordinationIDs:[]};
 const outputs={'audit:0':[bad],[step.dependencies[0]]:[good,bad]};
 const candidates=editorialRepairCandidate(JSON.stringify({points:[good,bad]}),p,step,outputs)!;
 assert.equal(candidates.length,2);
 const payload=summaryPayload(p,step,outputs,4,candidates),body=JSON.parse(payload.input);
 assert.deepEqual(body.repairs.map((x:any)=>x.index),[1]);assert.equal(body.records.length,1);
 const result=applyEditorialRepair(JSON.stringify({repairs:[{index:1,text:'Back pain — intermittent symptoms'}]}),candidates,p,step,outputs);
 assert.deepEqual(result[0],candidates[0]);assert.deepEqual(result[1],{...candidates[1],text:'Back pain — intermittent symptoms'});
 for(const repairs of [[],[{index:0,text:'Changed — accepted point'}],[{index:1,text:'Pain — is present'}],[{index:1,text:'Back pain — intermittent',citationIDs:['invented']}]] )assert.throws(()=>applyEditorialRepair(JSON.stringify({repairs}),candidates,p,step,outputs));
 assert.equal(editorialRepairCandidate(JSON.stringify({points:[{...bad,historyIDs:[]}]}),p,step,outputs),undefined);
 assert.equal(editorialRepairCandidate(JSON.stringify({points:[{...bad,citationIDs:['invented']}]}),p,step,outputs),undefined);
});
