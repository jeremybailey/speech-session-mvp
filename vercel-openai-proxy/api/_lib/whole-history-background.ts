import {database,transaction,submitWithinTransaction,validatePayload} from './ledger';
import {makeOverviewPayload} from './whole-history-overview';
import {jobQueue,queueJobID,jobTopic} from './queue';
import {runJob} from './worker';
const template=require('./whole-history-template.json');
export const wholeHistoryTopic=jobTopic;
export async function enqueueWholeHistory(id:string) {
 if(process.env.AI_QUEUE_ENABLED!=='true')throw Error('queue_unavailable');
 queueJobID({id});
 await jobQueue.send(wholeHistoryTopic,{id},{retentionSeconds:7*24*60*60,idempotencyKey:id});
}
export function chainedOverview(payload:any,output:string,parentID:string) {
 const source=JSON.parse(payload.input);
 if(source.serverOverview!==true||!Array.isArray(source.originalRecords))throw Error('invalid_request');
 const records=source.originalRecords.map((r:any)=>({id:r.originalID,text:r.passages.map((p:any)=>p.text).join(''),date:r.savedDate,title:r.title,sourceReference:r.sourceReference,sourceSHA256:r.sourceSHA256}));
 let proposal:unknown;try{proposal=JSON.parse(output);}catch{throw Error('invalid_proposal');}
 const built=makeOverviewPayload(records,proposal,template,source.version==='structured-plans-brief-v5').payload;
 return validatePayload({...built,stage:'whole-history-overview',workload_type:'incremental',input:JSON.stringify({...JSON.parse(built.input),requestIdentity:parentID})});
}
export function backgroundState(job:any) {
 if(job.payload?.whole_history_stop===true)return 'cancelled';
 if(job.result?.overview_error)return 'failed';
 return job.stage==='whole-history-generation'&&job.state==='completed'&&JSON.parse(job.payload?.input??'{}').serverOverview===true&&!job.result?.overviewJobID ? 'running' : job.state;
}
export async function runWholeHistory(id:string, runtime={database,transaction,runJob,submitWithinTransaction,enqueueWholeHistory}) {
 const initial=(await runtime.database().query('SELECT j.stage,p.payload FROM ai_jobs j JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1',[id])).rows[0];
 if(!initial||!['whole-history-generation','whole-history-overview'].includes(initial.stage))return false;
 await runtime.runJob(id); // Atomic claim prevents queue redelivery from repeating inference.
 if(initial.stage!=='whole-history-generation'||JSON.parse(initial.payload.input).serverOverview!==true)return true;
 const child=await runtime.transaction(async db=>{
  const parent=(await db.query('SELECT j.owner,j.state,p.payload,p.result FROM ai_jobs j JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1 FOR UPDATE OF j',[id])).rows[0];
  if(!parent||parent.state!=='completed'||parent.payload.whole_history_stop===true||parent.result?.overview_error)return;
  if(parent.result?.overviewJobID)return parent.result.overviewJobID as string;
  try {
   const payload=chainedOverview(parent.payload,parent.result.output,id);
   const receipt=await runtime.submitWithinTransaction(db,parent.owner,payload,undefined,'gpt-6-luna','medium');
   await db.query("UPDATE ai_payloads SET result=result||$2::jsonb WHERE job_id=$1",[id,JSON.stringify({overviewJobID:receipt.id})]);
   return receipt.id as string;
  }catch(error){
   const code=(error as Error).message;
   if(!['invalid_proposal','invalid_records','source_hash_mismatch','overview_context_limit','budget_exhausted'].includes(code))throw error;
   await db.query("UPDATE ai_payloads SET result=result||$2::jsonb WHERE job_id=$1",[id,JSON.stringify({overview_error:code})]);
  }
 });
 // Publication can be retried independently after the child identity is durable.
 if(child)await runtime.enqueueWholeHistory(child);
 return true;
}
export async function stopWholeHistory(owner:string,id:string) {
 return transaction(async db=>{
  const parent=(await db.query('SELECT p.result FROM ai_jobs j JOIN ai_payloads p ON p.job_id=j.id WHERE j.owner=$1 AND j.id=$2 FOR UPDATE OF j',[owner,id])).rows[0];
  if(!parent)return;
  await db.query("UPDATE ai_payloads SET payload=payload||'{\"whole_history_stop\":true}'::jsonb WHERE job_id=$1",[id]);
  return parent.result?.overviewJobID as string|undefined;
 });
}
