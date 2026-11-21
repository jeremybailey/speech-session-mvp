import {summaryActivity} from './summary-progress';
import {isRecordDeploymentActive} from './record-runtime';
import {newSummaryExecutionPolicy,summaryConcurrency,summaryReasoning,knownSummaryExecutionPolicy} from './summary-execution-policy';
import {createHmac} from 'node:crypto';
import {database,transaction,submitWithinTransaction,jsonbPayload} from './ledger';
import {runJob} from './worker';
import {mayReplaceUnconfirmedStep} from './summary-retry-policy';
import {jobQueue} from './queue';
import {canonical,digest,validateSummaryInput,summaryPlan,summaryPayload,validatePoints,editorialRepairCandidate,applyEditorialRepair,summaryResult,SummaryInput,Step,Point,confirmedSummaryProviderFailure,confirmedSummaryOutputLimit,isConcisePublicationStep} from './summary-workflow';
const active=['queued','running','retry_scheduled'];
export const summaryTopic='summary-workflows';
export function summariesEnabled(kind?:string){return process.env.AI_DURABLE_ENABLED==='true'&&process.env.AI_QUEUE_ENABLED==='true'&&process.env.AI_SUMMARY_WORKFLOWS_ENABLED==='true'&&(!kind||(process.env.AI_SUMMARY_WORKFLOW_KINDS??'practitioner').split(',').includes(kind));}
async function wake(db:any,id:string,seconds=0){await db.query(`INSERT INTO ai_summary_outbox(workflow_id,available_at) VALUES($1,now()+$2*interval '1 second') ON CONFLICT(workflow_id) DO UPDATE SET available_at=EXCLUDED.available_at,lease_until=NULL,fence=ai_summary_outbox.fence+1`,[id,seconds]);}
export async function submitSummary(owner:string,value:unknown,uploadExpiry?:Date){
 const input=validateSummaryInput(value);if(!summariesEnabled(input.kind))throw Error('summary_disabled');
 const secret=process.env.AI_DEDUPE_SECRET;if(!secret)throw Error('dedupe_secret_unavailable');
 const hash=createHmac('sha256',secret).update(canonical([owner,input])).digest('hex'),plan=summaryPlan(input);
 return transaction(async db=>{
  await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',['summary:'+owner]);
  if((await db.query('SELECT 1 FROM ai_summary_cancellations WHERE owner=$1 AND id=$2',[owner,input.id])).rows.length)return {id:input.id,state:'cancelled'};
  const old=(await db.query('SELECT owner,request_hash,id,state FROM ai_summary_workflows WHERE id=$1',[input.id])).rows[0];
  if(old){
   if(old.owner!==owner||old.request_hash!==hash)throw Error('revision_conflict');
   // One-time recovery of the founder workflow incorrectly self-superseded by
   // the pre-fix timestamp comparison. Existing provider receipts were restored
   // privately; only the identical frozen source request may reattach them.
   if(old.id==='25942f1c-8c7d-40e5-9f90-190f6cf52a38'&&old.state==='superseded'){
    const eligible=(await db.query(`SELECT 1 FROM ai_summary_workflows w WHERE w.id=$1 AND w.received_at IS NULL AND w.expires_at>now()
     AND NOT EXISTS(SELECT 1 FROM ai_summary_workflows n WHERE n.owner=w.owner AND n.target=w.target AND n.kind=w.kind AND n.id<>w.id AND n.created_at>w.created_at)`,[old.id])).rows.length;
    if(eligible){
     const rows=(await db.query('SELECT key,state,output FROM ai_summary_steps WHERE workflow_id=$1',[old.id])).rows;
     if(rows.length!==plan.length||rows.some(r=>!plan.some(s=>s.key===r.key)||!['queued','completed'].includes(r.state)))throw Error('recovery_not_ready');
     const outputs:Record<string,Point[]>={};
     for(const step of plan){const row=rows.find(r=>r.key===step.key)!;if(row.state==='completed')outputs[step.key]=validatePoints(JSON.stringify({points:row.output}),input,step,outputs);}
     if(Object.keys(outputs).length<25)throw Error('recovery_not_ready');
     await db.query('INSERT INTO ai_summary_payloads(workflow_id,input,plan) VALUES($1,$2,$3)',[old.id,jsonbPayload(input),jsonbPayload(plan)]);
     await db.query("UPDATE ai_summary_workflows SET state='queued',error_code=NULL,retry_at=NULL,revision=revision+1 WHERE id=$1",[old.id]);
     await wake(db,old.id);return {id:old.id,state:'queued'};
    }
   }
   return {id:old.id,state:old.state};
  }
  const budget=process.env.AI_BUDGET_ID;if(!budget)throw Error('budget_unavailable');
  // A new revision cannot publish an older pending operation for this target.
  const superseded=(await db.query("UPDATE ai_summary_workflows SET state='superseded',revision=revision+1 WHERE owner=$1 AND target=$2 AND kind=$3 AND state=ANY($4::text[]) RETURNING id",[owner,input.target,input.kind,active])).rows;
  for(const row of superseded)await purgeSummary(db,row.id);
  await db.query('INSERT INTO ai_summary_workflows(id,owner,request_hash,kind,target,budget_id,max_calls,execution_policy) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',[input.id,owner,hash,input.kind,input.target,budget,plan.length*2,newSummaryExecutionPolicy(input.kind)]);
  if(uploadExpiry)await db.query('UPDATE ai_summary_workflows SET expires_at=LEAST(expires_at,$2) WHERE id=$1',[input.id,uploadExpiry]);
  await db.query('INSERT INTO ai_summary_payloads(workflow_id,input,plan) VALUES($1,$2,$3)',[input.id,jsonbPayload(input),jsonbPayload(plan)]);
  for(const step of plan)await db.query('INSERT INTO ai_summary_steps(workflow_id,key) VALUES($1,$2)',[input.id,step.key]);
  await wake(db,input.id);return {id:input.id,state:'queued'};
 });
}
// Children are exclusively namespaced by parent and step in their payload. This
// prevents receipt deletion from erasing another workflow's live clinical data.
async function purgeSummary(db:any,id:string){
 const pending=(await db.query("SELECT j.id,j.budget_id,j.reserve_nusd FROM ai_jobs j JOIN ai_summary_children s ON s.job_id=j.id WHERE s.workflow_id=$1 AND j.state='queued' FOR UPDATE OF j",[id])).rows;
 for(const j of pending){await db.query("UPDATE ai_jobs SET state='cancelled',cost_nusd=0,finished_at=now() WHERE id=$1",[j.id]);await db.query('UPDATE ai_budgets SET reserved_nusd=reserved_nusd-$2 WHERE id=$1',[j.budget_id,j.reserve_nusd]);}
 await db.query('DELETE FROM ai_payloads WHERE job_id IN (SELECT job_id FROM ai_summary_children WHERE workflow_id=$1)',[id]);
 await db.query('UPDATE ai_summary_steps SET output=NULL WHERE workflow_id=$1',[id]);
 await db.query('DELETE FROM ai_summary_payloads WHERE workflow_id=$1',[id]);
 await db.query('DELETE FROM ai_summary_uploads WHERE id=$1 AND owner=(SELECT owner FROM ai_summary_workflows WHERE id=$1)',[id]);
 await db.query('DELETE FROM ai_summary_outbox WHERE workflow_id=$1',[id]);
}
export async function summaryStatus(owner:string,id:string){
 const row=(await database().query(`SELECT w.id,w.state,w.error_code,w.revision,w.expires_at,w.received_at,w.calls,w.max_calls,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('key',key,'state',state,'repair',output IS NOT NULL)), '[]'::jsonb) FROM ai_summary_steps WHERE workflow_id=w.id) activity_steps,
 (SELECT count(*)::int FROM ai_summary_steps WHERE workflow_id=w.id) total,
 (SELECT count(*)::int FROM ai_summary_steps WHERE workflow_id=w.id AND state='completed') completed,
 CASE WHEN w.state='completed' AND w.expires_at>now() THEN p.result ELSE NULL END output
 FROM ai_summary_workflows w LEFT JOIN ai_summary_payloads p ON p.workflow_id=w.id WHERE w.owner=$1 AND w.id=$2`,[owner,id])).rows[0];
 if(!row)return null;
 if(row.state==='needs_attention'&&row.calls>=row.max_calls)row.error_code='workflow_limit';
 if(new Date(row.expires_at).getTime()<=Date.now()&&!row.received_at){row.state='expired';row.output=null;}
 const activity=summaryActivity(row.state,row.activity_steps);delete row.activity_steps;
 return {...row,activity,...(row.output?{digest:digest(row.output)}:{})};
}
export async function acknowledgeSummary(owner:string,id:string,hash:string){return transaction(async db=>{
 await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',['summary:'+owner]);
 const w=(await db.query('SELECT * FROM ai_summary_workflows WHERE owner=$1 AND id=$2 FOR UPDATE',[owner,id])).rows[0];if(!w)throw Error('not_found');
 if(w.received_at)return {id,received:true};
 const p=(await db.query('SELECT result FROM ai_summary_payloads WHERE workflow_id=$1',[id])).rows[0];
 if(w.state!=='completed'||!p?.result||digest(p.result)!==hash)throw Error('receipt_mismatch');
 await db.query('UPDATE ai_summary_workflows SET received_at=now() WHERE id=$1',[id]);await purgeSummary(db,id);return {id,received:true};
});}
export async function cancelSummary(owner:string,id:string){return transaction(async db=>{
 await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',['summary:'+owner]);
 await db.query('INSERT INTO ai_summary_cancellations(owner,id) VALUES($1,$2) ON CONFLICT DO NOTHING',[owner,id]);
 await db.query('DELETE FROM ai_summary_uploads WHERE owner=$1 AND id=$2',[owner,id]);
 const w=(await db.query('SELECT * FROM ai_summary_workflows WHERE owner=$1 AND id=$2 FOR UPDATE',[owner,id])).rows[0];if(!w)return {id,state:'cancelled'};
 await db.query("UPDATE ai_summary_workflows SET state='cancelled',revision=revision+1 WHERE id=$1",[id]);await purgeSummary(db,id);return {id,state:'cancelled'};
});}
export async function resumeSummary(owner:string,id:string,expectedRevision?:number){return transaction(async db=>{
 const w=(await db.query('SELECT * FROM ai_summary_workflows WHERE owner=$1 AND id=$2 FOR UPDATE',[owner,id])).rows[0];if(!w)throw Error('not_found');
 // A late retry must not revive an attempt replaced by a newer record job.
 if(['needs_attention',...active].includes(w.state)&&(await db.query("SELECT 1 FROM ai_summary_workflows WHERE owner=$1 AND target=$2 AND kind=$3 AND id<>$4 AND created_at>(SELECT created_at FROM ai_summary_workflows WHERE id=$4) LIMIT 1",[owner,w.target,w.kind,id])).rows.length){
  await db.query("UPDATE ai_summary_workflows SET state='superseded',revision=revision+1 WHERE id=$1",[id]);
  await purgeSummary(db,id);return {id,state:'superseded'};
 }
 if(expectedRevision!==undefined&&(!Number.isSafeInteger(expectedRevision)||expectedRevision<0))throw Error('invalid_summary_input');
 if(expectedRevision!==undefined&&w.revision!==expectedRevision)return {id,state:w.state};
 if(w.state==='needs_attention'&&w.error_code==='budget_exhausted'&&new Date(w.expires_at)>new Date()){
 await db.query("UPDATE ai_summary_workflows SET state='queued',error_code=NULL WHERE id=$1",[id]);await wake(db,id);return {id,state:'queued'};}
 // Recover jobs stopped by the older billing-uncertainty classification.
 // Require every unfinished failure to have a confirmed failed receipt; never
 // reset completed steps, replay a running request, or release its reservation.
 if(w.state==='needs_attention'&&['provider_outcome_unknown','provider_failed'].includes(w.error_code)&&new Date(w.expires_at)>new Date()&&w.calls<w.max_calls){
  if(expectedRevision!==undefined)await db.query(`UPDATE ai_jobs j SET state='uncertain',finished_at=now() FROM ai_summary_steps s
   WHERE s.workflow_id=$1 AND s.job_id=j.id AND s.state='running' AND j.state='running'
   AND j.provider_id IS NULL AND j.started_at<now()-interval '10 minutes'`,[id]);
  const rows=(await db.query(`SELECT s.key,s.attempt,j.state job_state,j.provider_id,j.started_at,p.result FROM ai_summary_steps s
   JOIN ai_jobs j ON j.id=s.job_id LEFT JOIN ai_payloads p ON p.job_id=j.id AND p.expires_at>now()
   WHERE s.workflow_id=$1 AND s.state='running' AND j.state NOT IN ('queued','running','completed')`,[id])).rows;
  if(expectedRevision!==undefined&&rows.length&&rows.every((row:any)=>confirmedSummaryProviderFailure(row)||mayReplaceUnconfirmedStep(row))){
   // Explicit retry may replace an old receipt-less request once. Its unknown
   // charge stays reserved; completed steps and all original child IDs survive.
   // Increment attempts to preserve deduplication and retain all child receipts.
   for(const row of rows)await db.query("UPDATE ai_summary_steps SET state='queued',attempt=attempt+1,job_id=NULL,error_code=NULL WHERE workflow_id=$1 AND key=$2",[id,row.key]);
   await db.query("UPDATE ai_summary_workflows SET state='queued',error_code=NULL,retry_at=NULL,revision=revision+1 WHERE id=$1",[id]);
   await wake(db,id);return {id,state:'queued'};
  }
  if(rows.length&&rows.every((row:any)=>confirmedSummaryProviderFailure(row)&&row.attempt<2)){
   await db.query("UPDATE ai_summary_workflows SET state='queued',error_code=NULL,retry_at=NULL WHERE id=$1",[id]);
   await wake(db,id);return {id,state:'queued'};
  }
 }
 // Resume only a confirmed output-limit failure, retaining all checked work.
 if(w.state==='needs_attention'&&w.error_code==='incomplete'&&new Date(w.expires_at)>new Date()&&w.calls<w.max_calls){
  const rows=(await db.query(`SELECT s.attempt,j.state job_state,j.provider_id,p.result FROM ai_summary_steps s
   JOIN ai_jobs j ON j.id=s.job_id LEFT JOIN ai_payloads p ON p.job_id=j.id AND p.expires_at>now()
   WHERE s.workflow_id=$1 AND s.state='running' AND j.state NOT IN ('queued','running','completed')`,[id])).rows;
  if(rows.length&&rows.every((row:any)=>confirmedSummaryOutputLimit(row)&&row.attempt<2)){
   await db.query("UPDATE ai_summary_workflows SET state='queued',error_code=NULL,retry_at=NULL,revision=revision+1 WHERE id=$1",[id]);
   await wake(db,id);return {id,state:'queued'};
  }
 }
 // A formatting-only repair can retain the already checked original wording.
 // Revalidate the saved receipt before waking; never rerun completed source work.
 if(w.state==='needs_attention'&&w.error_code==='invalid_summary_output'&&new Date(w.expires_at)>new Date()){
  const p=(await db.query('SELECT input,plan FROM ai_summary_payloads WHERE workflow_id=$1',[id])).rows[0];
  const rows=(await db.query(`SELECT s.key,s.state,s.attempt,s.output,j.state job_state,p.result FROM ai_summary_steps s
   LEFT JOIN ai_jobs j ON j.id=s.job_id LEFT JOIN ai_payloads p ON p.job_id=j.id AND p.expires_at>now() WHERE s.workflow_id=$1`,[id])).rows;
  const outputs=Object.fromEntries(rows.filter((r:any)=>r.state==='completed').map((r:any)=>[r.key,r.output]));
  const unfinished=rows.filter((r:any)=>r.state!=='completed');
  const recoverable=p&&unfinished.length>0&&unfinished.every((r:any)=>{
   if(r.state!=='running'||r.job_state!=='completed')return false;
   try{const step=p.plan.find((s:Step)=>s.key===r.key);if(r.output){applyEditorialRepair(r.result?.output,r.output,p.input,step,outputs,true);return true;}return r.attempt>=3&&!!editorialRepairCandidate(r.result?.output,p.input,step,outputs);}catch{return false;}
  });
  if(recoverable){
   await db.query("UPDATE ai_summary_workflows SET state='queued',error_code=NULL,retry_at=NULL,revision=revision+1 WHERE id=$1",[id]);
   await wake(db,id);return {id,state:'queued'};
  }
 }
 // Unknown provider outcomes and invalid clinical output are never blindly retried.
 return {id,state:w.state};
});}
export async function advanceSummary(id:string):Promise<string[]>{return transaction(async db=>{
 const identity=(await db.query('SELECT owner FROM ai_summary_workflows WHERE id=$1',[id])).rows[0];if(!identity)return [];
 await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',['summary:'+identity.owner]);
 const w=(await db.query('SELECT * FROM ai_summary_workflows WHERE id=$1 FOR UPDATE',[id])).rows[0];
 if(!active.includes(w.state))return [];
 if(!knownSummaryExecutionPolicy(w.execution_policy))throw Error('summary_policy_unsupported');
 // Transaction-local: an older deployed coordinator cannot silently downgrade
 // this workflow's frozen policy. The database fence rolls back its admission.
 await db.query("SELECT set_config('collectivecare.summary_execution_policy',$1,true)",[w.execution_policy]);
 if(w.retry_at&&new Date(w.retry_at)>new Date())return [];
 if(new Date(w.expires_at)<=new Date()){await db.query("UPDATE ai_summary_workflows SET state='expired' WHERE id=$1",[id]);await purgeSummary(db,id);return [];}
 const p=(await db.query('SELECT input,plan FROM ai_summary_payloads WHERE workflow_id=$1',[id])).rows[0];if(!p)return [];
 const input=p.input as SummaryInput,plan=p.plan as Step[];
 const rows=(await db.query(`SELECT s.*,j.state job_state,j.created_at job_created,j.provider_id,p.result FROM ai_summary_steps s LEFT JOIN ai_jobs j ON j.id=s.job_id LEFT JOIN ai_payloads p ON p.job_id=j.id AND p.expires_at>now() WHERE s.workflow_id=$1`,[id])).rows;
 const outputs:Record<string,Point[]>={};for(const r of rows)if(r.state==='completed')outputs[r.key]=r.output;
 for(const row of rows.filter((r:any)=>r.state==='running')){
  if(['queued','running'].includes(row.job_state))continue;
  let failure:string|undefined;let editorialRepair=false;
  if(row.job_state==='completed'){
   try {const step=plan.find(s=>s.key===row.key)!;const result=row.output?applyEditorialRepair(row.result?.output,row.output,input,step,outputs,true):validatePoints(row.result?.output,input,step,outputs);outputs[row.key]=result;row.state='completed';await db.query("UPDATE ai_summary_steps SET state='completed',output=$3 WHERE workflow_id=$1 AND key=$2",[id,row.key,jsonbPayload(result)]);continue;}
   catch {failure='invalid_summary_output';if(!row.output){const candidate=editorialRepairCandidate(row.result?.output,input,plan.find(s=>s.key===row.key)!,outputs);if(candidate){
    if(row.attempt>=3){outputs[row.key]=candidate;row.state='completed';await db.query("UPDATE ai_summary_steps SET state='completed',output=$3 WHERE workflow_id=$1 AND key=$2",[id,row.key,jsonbPayload(candidate)]);continue;}
    row.output=candidate;editorialRepair=true;await db.query('UPDATE ai_summary_steps SET output=$3 WHERE workflow_id=$1 AND key=$2',[id,row.key,jsonbPayload(candidate)]);}}}
  }else failure=confirmedSummaryProviderFailure(row)?'provider_failed':row.job_state==='uncertain'?'provider_outcome_unknown':row.job_state??'missing_provider_result';
  const providerFailed=confirmedSummaryProviderFailure(row);
  const outputLimited=confirmedSummaryOutputLimit(row);
  const transient=providerFailed || outputLimited || row.job_state==='incomplete'&&[429,502,503,504].includes(row.result?.diagnostics?.providerHTTPStatus);
  const repair=editorialRepair||failure==='invalid_summary_output'&&row.attempt<(isConcisePublicationStep(input,plan.find(s=>s.key===row.key)!)?3:1);
  if((repair||transient&&row.attempt<(providerFailed||outputLimited?2:5))&&w.calls<w.max_calls){
   row.state='queued';row.attempt++;row.job_id=null;
   await db.query("UPDATE ai_summary_steps SET state='queued',attempt=$3,job_id=NULL,error_code=$4 WHERE workflow_id=$1 AND key=$2",[id,row.key,row.attempt,failure]);
   // Archive every child ID for expiry/receipt cleanup, including rejected attempts.
   const delay=transient?Math.min(60,2**row.attempt)+Math.floor(Math.random()*3):0;
   await db.query("UPDATE ai_summary_workflows SET state='retry_scheduled',retry_at=now()+$2*interval '1 second' WHERE id=$1",[id,delay]);
   await wake(db,id,delay);return [];
  }else {await db.query("UPDATE ai_summary_workflows SET state='needs_attention',error_code=$2,revision=revision+1 WHERE id=$1",[id,failure]);await db.query('DELETE FROM ai_summary_outbox WHERE workflow_id=$1',[id]);return [];}
 }
 if(rows.every((r:any)=>r.state==='completed')){
  try {const result=canonical(summaryResult(input,plan,outputs));await db.query('UPDATE ai_summary_payloads SET result=$2 WHERE workflow_id=$1',[id,result]);await db.query("UPDATE ai_summary_workflows SET state='completed',revision=revision+1,error_code=NULL WHERE id=$1",[id]);await db.query('DELETE FROM ai_summary_outbox WHERE workflow_id=$1',[id]);}
  catch {await db.query("UPDATE ai_summary_workflows SET state='needs_attention',error_code='unsupported_summary' WHERE id=$1",[id]);}
  return [];
 }
 const concurrent=Number((await db.query("SELECT count(*) FROM ai_summary_steps s JOIN ai_summary_workflows w ON w.id=s.workflow_id WHERE w.owner=$1 AND w.state=ANY($2::text[]) AND s.state='running'",[w.owner,active])).rows[0].count);
 let slots=Math.max(0,summaryConcurrency(w.execution_policy)-concurrent),calls=Number(w.calls);
 for(const step of plan){const row=rows.find((r:any)=>r.key===step.key);if(!slots||row.state!=='queued'||!step.dependencies.every(k=>outputs[k]!==undefined))continue;
  if(calls>=w.max_calls){await db.query("UPDATE ai_summary_workflows SET state='needs_attention',error_code='workflow_limit' WHERE id=$1",[id]);return [];}
  try {
   const payload=summaryPayload(input,step,outputs,row.attempt,row.output??undefined);
   const child=await submitWithinTransaction(db,w.owner,payload,w.budget_id,'gpt-6-luna',summaryReasoning(w.execution_policy,step));
   await db.query('INSERT INTO ai_summary_children(workflow_id,job_id) VALUES($1,$2) ON CONFLICT DO NOTHING',[id,child.id]);
   await db.query('UPDATE ai_payloads SET expires_at=LEAST(expires_at,$2) WHERE job_id=$1',[child.id,w.expires_at]);
   await db.query("UPDATE ai_summary_steps SET state='running',job_id=$3 WHERE workflow_id=$1 AND key=$2",[id,step.key,child.id]);row.state='running';row.job_id=child.id;calls++;slots--;
  } catch(error){
   if((error as Error).message!=='budget_exhausted')throw error;
   // Outstanding reservations are temporary pressure, not exhausted spending.
   // Let already admitted work run and release its unused reservation first.
   const pending=(await db.query("SELECT 1 FROM ai_jobs WHERE budget_id=$1 AND state IN ('queued','running') LIMIT 1",[w.budget_id])).rows.length;
   if(pending)break;
   await db.query("UPDATE ai_summary_workflows SET state='needs_attention',error_code='budget_exhausted',calls=$2 WHERE id=$1",[id,calls]);return [];
  }
 }
 await db.query("UPDATE ai_summary_workflows SET state='running',calls=$2,revision=revision+1 WHERE id=$1",[id,calls]);
 await wake(db,id,5);return rows.filter((r:any)=>r.state==='running').map((r:any)=>r.job_id);
});}
export async function runSummary(id:string,execute:(id:string)=>Promise<number>=runJob){
 if(!summariesEnabled())throw Error('summary_disabled');
 const children=await advanceSummary(id);
 const results=await Promise.allSettled(children.map(child=>execute(child)));
 await advanceSummary(id);
 // Provider-pending and worker interruptions are recovered by persisted dispatches.
 if(results.some(r=>r.status==='rejected'))console.info('summary_child_pending',JSON.stringify({id}));
}
export async function dispatchSummaries(){
 if(!summariesEnabled()||!await isRecordDeploymentActive())return 0;
 const rows=await transaction(async db=>{
  await db.query("SELECT set_config('collectivecare.summary_dispatch','v2',true)");
  const due=(await db.query(`SELECT o.workflow_id FROM ai_summary_outbox o JOIN ai_summary_workflows w ON w.id=o.workflow_id WHERE o.available_at<=now()+interval '60 seconds' AND (o.lease_until IS NULL OR o.lease_until<now()) AND w.state=ANY($1::text[]) AND w.expires_at>now() ORDER BY o.available_at LIMIT 100 FOR UPDATE OF o SKIP LOCKED`,[active])).rows;
  const result=[];for(const r of due)result.push((await db.query("UPDATE ai_summary_outbox SET lease_until=GREATEST(now(),available_at)+interval '60 seconds',fence=fence+1 WHERE workflow_id=$1 RETURNING workflow_id,fence,available_at",[r.workflow_id])).rows[0]);return result;
 });
 for(const r of rows){try{await jobQueue.send(summaryTopic,{id:r.workflow_id},{idempotencyKey:`${r.workflow_id}:${r.fence}`,delaySeconds:Math.max(0,Math.min(60,Math.ceil((new Date(r.available_at).getTime()-Date.now())/1000))),retentionSeconds:604800});}catch{await database().query('UPDATE ai_summary_outbox SET lease_until=NULL WHERE workflow_id=$1 AND fence=$2',[r.workflow_id,r.fence]);}}
 return rows.length;
}
export async function cleanupSummaries(){
 if(!(await database().query("SELECT to_regclass('public.ai_summary_workflows') name")).rows[0].name)return;
 await transaction(async db=>{
 const rows=(await db.query("SELECT id FROM ai_summary_workflows WHERE expires_at<=now() AND received_at IS NULL AND state<>'expired' FOR UPDATE SKIP LOCKED")).rows;
 for(const w of rows){await db.query("UPDATE ai_summary_workflows SET state='expired',revision=revision+1 WHERE id=$1",[w.id]);await purgeSummary(db,w.id);}
 });
}
