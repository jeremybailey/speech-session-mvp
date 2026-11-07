import {randomUUID} from 'node:crypto';
import {database,transaction,submitWithinTransaction} from './ledger';
import {enqueueJob,jobQueue,jobTopic} from './queue';
import {isRecordDeploymentActive} from './record-runtime';
import {storyPayload,storyResult} from './story-contract';
import {runJob} from './worker';

export async function advanceStoryOperation(owner:string,id:string) {
 let op=(await database().query('SELECT * FROM ai_story_operations WHERE owner=$1 AND id=$2',[owner,id])).rows[0];
 if(!op)return {state:'not_found'};
 if(op.cancelled)return {state:'cancelled'};
 if(!op.request||Date.now()-new Date(op.created_at).getTime()>=7*86400000)return {state:'expired'};
 if(!await isRecordDeploymentActive())return {state:'queued'};
 if(op.next_attempt_at && new Date(op.next_attempt_at).getTime()>Date.now())return {state:'retry_scheduled'};
 async function retryIfEligible(failed:any,phase:'job_id'|'check_job_id',candidate?:unknown):Promise<boolean>{
  const transient=failed.state==='incomplete'&&failed.result?.diagnostics?.providerHTTPStatus===429;
  const ambiguous=failed.state==='uncertain'&&Date.now()-new Date(failed.created_at).getTime()>=15*60_000;
  if(!transient&&!ambiguous)return false;
  const next=await transaction(async db=>{
   const current=(await db.query('SELECT * FROM ai_story_operations WHERE owner=$1 AND id=$2 FOR UPDATE',[owner,id])).rows[0];
   // Reserve one slot for independent verification when replacing extraction.
   const cap=phase==='job_id'?2:3;
   if(current.cancelled||current.attempts>=cap||current[phase]!==op[phase]||!current.request||!await isRecordDeploymentActive(db))return;
   const receipt=await submitWithinTransaction(db,owner,storyPayload(current.request,candidate),undefined,'gpt-6-luna','medium','story:'+id,randomUUID());
   await db.query(`UPDATE ai_story_operations SET ${phase}=$3,attempts=attempts+1,next_attempt_at=now()+interval '30 seconds' WHERE owner=$1 AND id=$2`,[owner,id,receipt.id]);
   return receipt.id as string;
  });
  if(next&&process.env.AI_QUEUE_ENABLED==='true')await jobQueue.send(jobTopic,{id:next},{delaySeconds:30,idempotencyKey:next+':retry'});
  return Boolean(next);
 }
 async function job(id:string){return (await database().query('SELECT j.state,j.created_at,CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END AS result FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1 AND j.owner=$2',[id,owner])).rows[0];}
 const first=await job(op.job_id);
 if(!first)return {state:'blocked'};
 if(first.state==='queued')await enqueueJob(op.job_id);
 if(first.state!=='completed'){if(await retryIfEligible(first,'job_id'))return {state:'retry_scheduled'};return {state:first.state==='uncertain'&&op.attempts<2&&Date.now()-new Date(first.created_at).getTime()<15*60_000?'reconciling':first.state};}
 if(!first.result)return {state:'expired'};
 const candidate=storyResult(first.result.output,op.request);
 if(!op.check_job_id){await transaction(async db=>{
  const current=(await db.query('SELECT * FROM ai_story_operations WHERE owner=$1 AND id=$2 FOR UPDATE',[owner,id])).rows[0];
  if(current.cancelled||current.check_job_id||!current.request||!await isRecordDeploymentActive(db))return;
  const check=await submitWithinTransaction(db,owner,storyPayload(current.request,candidate),undefined,'gpt-6-luna','medium');
  await db.query('UPDATE ai_story_operations SET check_job_id=$3,attempts=attempts+1 WHERE owner=$1 AND id=$2',[owner,id,check.id]);
 });op=(await database().query('SELECT * FROM ai_story_operations WHERE owner=$1 AND id=$2',[owner,id])).rows[0];}
 if(op.cancelled)return {state:'cancelled'};
 if(!op.check_job_id)return {state:'queued'};
 const checked=await job(op.check_job_id);
 if(!checked)return {state:'blocked'};
 if(checked.state==='queued')await enqueueJob(op.check_job_id);
 if(checked.state!=='completed'){if(await retryIfEligible(checked,'check_job_id',candidate))return {state:'queued'};return {state:checked.state};}
 if(!checked.result)return {state:'expired'};
 const result=storyResult(checked.result.output,op.request);
 const latest=(await database().query('SELECT cancelled FROM ai_story_operations WHERE owner=$1 AND id=$2',[owner,id])).rows[0];
 return latest?.cancelled?{state:'cancelled'}:{state:'completed',result};
}

// Both inference and independent checking continue without an open phone.
export async function runStoryJob(jobID:string):Promise<boolean>{
 if(process.env.STORY_LAB_ENABLED!=='true')return false;
 const op=(await database().query('SELECT owner,id,cancelled,next_attempt_at FROM ai_story_operations WHERE job_id=$1 OR check_job_id=$1',[jobID])).rows[0];
 if(!op)return false;
 if(op.cancelled||!await isRecordDeploymentActive())return true;
 if(op.next_attempt_at&&new Date(op.next_attempt_at).getTime()>Date.now()) {
  if(process.env.AI_QUEUE_ENABLED==='true')await jobQueue.send(jobTopic,{id:jobID},{delaySeconds:30,idempotencyKey:jobID+':backoff:'+Math.floor(Date.now()/30000)});
  return true;
 }
 await runJob(jobID);
 const status=await advanceStoryOperation(op.owner,op.id);
 if(['reconciling','retry_scheduled'].includes(status.state)&&process.env.AI_QUEUE_ENABLED==='true')await jobQueue.send(jobTopic,{id:jobID},{delaySeconds:60,idempotencyKey:jobID+':reconcile:'+Math.floor(Date.now()/60000)});
 return true;
}
