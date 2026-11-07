import {isRecordDeploymentActive} from './record-runtime';
import {snapshotPayload,validateSnapshot,validateSnapshotOverview} from './incremental-overview';
import {randomUUID} from 'node:crypto';
import {database,transaction,submitWithinTransaction,cancel,Payload} from './ledger';
import {runJob,ProviderResponsePending} from './worker';
import {jobQueue} from './queue';
import {incrementalVersion,splitRecords,extractionPayload,verificationPayload,parseFacts,parseExtractionBatch,acceptFacts,digest,RecordInput} from './incremental-contract';

export const recordUpdateTopic='health-record-updates';
export const incrementalValidator='incremental-validator-v4';
const terminal=['completed','completed_with_withheld_items','blocked','cancelled'];
export function recoveryDecision(state:string,attempts:number,age:number,replaced:boolean,http?:number):'wait'|'retry'|'block'{
 if(state==='queued'||state==='running')return 'wait';
 if(attempts>=3||[400,401,403,404,413,422].includes(http??0))return 'block';
 if(state==='uncertain')return age<15*60_000?'wait':replaced?'block':'retry';
 return ['incomplete','expired'].includes(state)?'retry':'block';
}
export async function enqueueRecordUnit(id:string,delay=0){
 await jobQueue.send(recordUpdateTopic,{id},{delaySeconds:delay,idempotencyKey:`${id}:${Math.floor(Date.now()/5000)}:${delay}`});
}
export async function createRecordUpdate(owner:string,id:string,records:RecordInput[],manifest:unknown){
 if(!await isRecordDeploymentActive())throw Error('deployment_inactive');
 const units=splitRecords(records);const requestHash=digest(JSON.stringify(units.map(u=>u.key)));
 await transaction(async db=>{
  await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[id]);
  const prior=(await db.query('SELECT owner,manifest,expires_at FROM ai_record_updates WHERE id=$1',[id])).rows[0];
  if(prior){if(prior.owner!==owner||prior.manifest.requestHash!==requestHash)throw Error('invalid_run');if(new Date(prior.expires_at).getTime()<=Date.now())throw Error('result_expired');return;}
  await db.query('INSERT INTO ai_record_updates(id,owner,contract,manifest) VALUES($1,$2,$3,$4)',[id,owner,incrementalVersion,{requestHash,release:manifest}]);
  for(const unit of units)await db.query('INSERT INTO ai_record_units(id,update_id,unit_key,source_hash,source) VALUES($1,$2,$3,$4,$5)',[randomUUID(),id,unit.key,unit.sourceHash,unit]);
 });
 await scheduleRecordUpdate(id);
}
export async function scheduleRecordUpdate(id:string){
 if(!await isRecordDeploymentActive())return;
 const ids=await transaction(async db=>{
  const parent=(await db.query('SELECT * FROM ai_record_updates WHERE id=$1 FOR UPDATE',[id])).rows[0];
  if(!parent||parent.stopped||new Date(parent.expires_at).getTime()<=Date.now())return [];
  const active=(await db.query("SELECT id FROM ai_record_units WHERE update_id=$1 AND state IN ('running','reconciling','retry_scheduled')",[id])).rows;
  const pending=(await db.query("SELECT id FROM ai_record_units WHERE update_id=$1 AND state='queued' ORDER BY unit_key LIMIT $2 FOR UPDATE",[id,Math.max(0,4-active.length)])).rows;
  for(const u of pending)await db.query("UPDATE ai_record_units SET state='running' WHERE id=$1",[u.id]);
  const all=(await db.query('SELECT state FROM ai_record_units WHERE update_id=$1',[id])).rows;
  const done=all.every(u=>terminal.includes(u.state));
  const state=done?(all.some(u=>u.state!=='completed')?'completed_with_withheld_items':'completed'):'running';
  await db.query('UPDATE ai_record_updates SET state=$2 WHERE id=$1',[id,state]);
  // Redeliver active units too: a crash between committing and enqueueing is recoverable.
  return [...active,...pending].map(u=>u.id as string);
 });
 await Promise.all(ids.map(id=>enqueueRecordUnit(id)));
}
export async function runRecordUnit(id:string){
 if(!await isRecordDeploymentActive())return;
 let unit=(await database().query('SELECT u.*,p.owner,p.stopped,p.expires_at FROM ai_record_units u JOIN ai_record_updates p ON p.id=u.update_id WHERE u.id=$1',[id])).rows[0];
 if(!unit||unit.stopped||terminal.includes(unit.state)||new Date(unit.expires_at).getTime()<=Date.now())return;
 if(new Date(unit.next_attempt_at).getTime()>Date.now()){
  await enqueueRecordUnit(id,Math.ceil((new Date(unit.next_attempt_at).getTime()-Date.now())/1000));return;
 }
 if(!unit.job_id){
  try{await transaction(async db=>{
   const current=(await db.query('SELECT u.*,p.owner,p.stopped FROM ai_record_units u JOIN ai_record_updates p ON p.id=u.update_id WHERE u.id=$1 FOR UPDATE OF p,u',[id])).rows[0];
   if(!current||current.stopped||current.job_id||terminal.includes(current.state)||!await isRecordDeploymentActive(db))return;
   if(current.attempts>=3){await db.query("UPDATE ai_record_units SET state='blocked',diagnostic='attempt_limit' WHERE id=$1",[id]);return;}
   const identity=`${id}:${current.phase}:${current.attempts+1}`;
   const payload:Payload=current.phase==='overview'||current.phase==='overview-verify'
    ?snapshotPayload(current.source.snapshot,identity,current.phase==='overview-verify'?current.candidate:undefined)
    :current.phase==='extract'?extractionPayload(current.source,identity,current.source.repair):verificationPayload(current.source,current.candidate,identity);
   const receipt=await submitWithinTransaction(db,current.owner,payload,undefined,'gpt-6-luna','medium');
   await db.query("UPDATE ai_record_units SET job_id=$2,attempts=attempts+1,state='running' WHERE id=$1",[id,receipt.id]);
  });}catch(error){
   if(['budget_exhausted','budget_unavailable','model_unavailable'].includes((error as Error).message)){
    await database().query("UPDATE ai_record_units SET state='blocked',diagnostic=$2 WHERE id=$1",[id,(error as Error).message]);await scheduleRecordUpdate(unit.update_id);return;
   }throw error;
  }
  unit=(await database().query('SELECT * FROM ai_record_units WHERE id=$1',[id])).rows[0];
 }
 if(!unit.job_id){await scheduleRecordUpdate(unit.update_id);return;}
 try{await runJob(unit.job_id);}catch(error){
  // Poll again even when provider submission was ambiguous; the ledger owns accounting.
  if(!(error instanceof ProviderResponsePending)&&!['provider_receipt_pending','job_running'].includes((error as Error).message))throw error;
 }
 const job=(await database().query('SELECT j.*,p.result FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id AND p.expires_at>now() WHERE j.id=$1',[unit.job_id])).rows[0];
 if(!job)throw Error('job_missing');
 if(job.state!=='completed'){
  const age=Date.now()-new Date(job.started_at??job.created_at).getTime();
  const decision=recoveryDecision(job.state,unit.attempts,age,unit.uncertain_replaced,job.result?.diagnostics?.providerHTTPStatus);
  if(decision==='wait'){
   await database().query("UPDATE ai_record_units SET state=$2 WHERE id=$1 AND job_id=$3 AND state NOT IN ('cancelled','blocked','completed','completed_with_withheld_items')",[id,job.state==='uncertain'?'reconciling':'running',job.id]);
   await enqueueRecordUnit(id,job.state==='uncertain'?30:5);return;
  }
  await database().query("UPDATE ai_record_units SET state=$2,next_attempt_at=now()+interval '1 second' * LEAST(60,5*power(2,attempts)),job_id=CASE WHEN $2='retry_scheduled' THEN NULL ELSE job_id END,uncertain_replaced=uncertain_replaced OR $3,diagnostic=$4 WHERE id=$1 AND job_id=$5 AND state NOT IN ('cancelled','blocked','completed','completed_with_withheld_items')",[id,decision==='retry'?'retry_scheduled':'blocked',job.state==='uncertain',job.state,job.id]);
  if(decision==='retry')await enqueueRecordUnit(id,Math.min(60,5*Math.pow(2,unit.attempts)));
  else await scheduleRecordUpdate(unit.update_id);
  return;
 }
 await transaction(async db=>{
  const current=(await db.query('SELECT u.*,p.stopped FROM ai_record_units u JOIN ai_record_updates p ON p.id=u.update_id WHERE u.id=$1 FOR UPDATE OF p,u',[id])).rows[0];
  if(!current||current.stopped||current.job_id!==job.id||terminal.includes(current.state)||!await isRecordDeploymentActive(db))return;
  await db.query('UPDATE ai_record_units SET validator_version=$2,worker_deployment_id=$3 WHERE id=$1',[id,incrementalValidator,process.env.VERCEL_DEPLOYMENT_ID??null]);
  try{
   if(current.phase==='overview'){
    const candidate=validateSnapshotOverview(job.result.output,current.source.snapshot);
    await db.query("UPDATE ai_record_units SET candidate=$2,phase='overview-verify',job_id=NULL,state='retry_scheduled' WHERE id=$1",[id,candidate]);
   }else if(current.phase==='overview-verify'){
    const check=JSON.parse(job.result.output);
    if(typeof check.supported!=='boolean')throw Error('invalid_verification');
    if(!check.supported && check.repair && current.attempts<3){
     const repaired=validateSnapshotOverview(JSON.stringify(check.repair),current.source.snapshot);
     await db.query("UPDATE ai_record_units SET candidate=$2,job_id=NULL,state='retry_scheduled',diagnostic='overview_repair_pending' WHERE id=$1",[id,repaired]);
    }else{
     await db.query('UPDATE ai_record_units SET result=$2,state=$3,diagnostic=$4 WHERE id=$1',[id,check.supported?{overview:current.candidate}:null,check.supported?'completed':'blocked',check.supported?null:'unsupported_overview']);
    }
   }else if(current.phase==='extract'){
    const batch=parseExtractionBatch(job.result.output,current.source);
    if(!batch.facts.length && batch.withheld)throw Error('invalid_unit');
    await db.query("UPDATE ai_record_units SET candidate=$2,source=$3,phase='verify',job_id=NULL,state='retry_scheduled' WHERE id=$1",[id,JSON.stringify(batch.facts),{...current.source,extractionWithheld:batch.withheld}]);
   }else{
    const result=acceptFacts(job.result.output,current.candidate,current.source);
    result.withheld+=current.source.extractionWithheld??0;
    const partial=result.withheld>0||result.omissions.length>0;
    await db.query('UPDATE ai_record_units SET result=$2,state=$3 WHERE id=$1',[id,result,partial?'completed_with_withheld_items':'completed']);
    // A repair consumes the remaining third call of this source unit's budget.
    // The checker proposes candidates; a separate call must validate them.
    if(partial&&!current.source.repair&&current.attempts<3){
     let repairs:ReturnType<typeof parseFacts>=[];
     try {repairs=parseFacts(JSON.stringify({facts:JSON.parse(job.result.output).repairs??[]}),current.source);} catch { /* Keep valid base facts even if repair proposals are malformed. */ }
     if(repairs.length){
      const source={...current.source,key:current.source.key+':repair',repair:true,extractionWithheld:0};
      await db.query("INSERT INTO ai_record_units(id,update_id,unit_key,source_hash,source,phase,candidate,attempts) VALUES($1,$2,$3,$4,$5,'verify',$6,$7) ON CONFLICT(update_id,unit_key) DO NOTHING",[randomUUID(),current.update_id,source.key,current.source_hash,source,JSON.stringify(repairs),current.attempts]);
     }
    }
   }
  }catch{
   await db.query("UPDATE ai_record_units SET state=$2,next_attempt_at=now()+interval '1 second' * LEAST(60,5*power(2,attempts)),job_id=CASE WHEN $2='retry_scheduled' THEN NULL ELSE job_id END,diagnostic='invalid_result' WHERE id=$1",[id,current.attempts<3?'retry_scheduled':'blocked']);
  }
 });
 await scheduleRecordUpdate(unit.update_id);
}
export async function recordUpdateStatus(owner:string,id:string){
 const p=(await database().query('SELECT id,state,stopped,contract,manifest,expires_at FROM ai_record_updates WHERE id=$1 AND owner=$2',[id,owner])).rows[0];
 if(!p)throw Error('not_found');if(new Date(p.expires_at).getTime()<=Date.now())throw Error('result_expired');
 const units=(await database().query(`SELECT id,unit_key,source_hash,state,result,diagnostic,source->>'recordID' AS record_id FROM ai_record_units WHERE update_id=$1 ORDER BY unit_key`,[id])).rows;
 return {...p,units};
}
export async function stopRecordUpdate(owner:string,id:string){
 const jobs=await transaction(async db=>{
  const p=(await db.query('SELECT id FROM ai_record_updates WHERE id=$1 AND owner=$2 FOR UPDATE',[id,owner])).rows[0];if(!p)throw Error('not_found');
  await db.query("UPDATE ai_record_updates SET stopped=true,state='cancelled' WHERE id=$1",[id]);
  return (await db.query("UPDATE ai_record_units SET state='cancelled' WHERE update_id=$1 AND state NOT IN ('completed','completed_with_withheld_items') RETURNING job_id",[id])).rows;
 });
 await Promise.all(jobs.filter(j=>j.job_id).map(j=>cancel(owner,j.job_id)));
}
export async function resumeRecordJob(jobID:string):Promise<boolean>{
 const units=(await database().query('SELECT id FROM ai_record_units WHERE job_id=$1',[jobID])).rows;
 for(const u of units)await enqueueRecordUnit(u.id);return units.length>0;
}

export async function createSnapshotUpdate(owner:string,id:string,value:unknown,manifest:unknown){
 if(!await isRecordDeploymentActive())throw Error('deployment_inactive');
 const snapshot=validateSnapshot(value),requestHash=digest(JSON.stringify(snapshot));
 await transaction(async db=>{
  await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[id]);
  const prior=(await db.query('SELECT owner,manifest,expires_at FROM ai_record_updates WHERE id=$1',[id])).rows[0];
  if(prior){if(prior.owner!==owner||prior.manifest.requestHash!==requestHash)throw Error('invalid_run');if(new Date(prior.expires_at).getTime()<=Date.now())throw Error('result_expired');return;}
  await db.query('INSERT INTO ai_record_updates(id,owner,contract,manifest) VALUES($1,$2,$3,$4)',[id,owner,incrementalVersion,{requestHash,release:manifest}]);
  await db.query("INSERT INTO ai_record_units(id,update_id,unit_key,source_hash,source,phase) VALUES($1,$2,$3,$4,$5,'overview')",[randomUUID(),id,'overview:'+requestHash,snapshot.fingerprint,{snapshot}]);
 });
 await scheduleRecordUpdate(id);
}

/** Replay only saved independent checker output under an explicitly compatible validator.
 * No provider job is submitted, no attempts reset, no cancelled or expired work revived. */
export async function revalidateRecordUpdate(owner:string,id:string){
 if(!await isRecordDeploymentActive())return 0;
 const units=await transaction(async db=>{
  const p=(await db.query('SELECT * FROM ai_record_updates WHERE id=$1 AND owner=$2 FOR UPDATE',[id,owner])).rows[0];
  if(!p)throw Error('not_found');
  if(p.stopped||new Date(p.expires_at).getTime()<=Date.now()||p.contract!==incrementalVersion)return [];
  const result=await db.query(`UPDATE ai_record_units u SET state='running',diagnostic=NULL,next_attempt_at=now()
    FROM ai_jobs j,ai_payloads payload WHERE u.update_id=$1 AND u.job_id=j.id AND payload.job_id=j.id
    AND u.state='blocked' AND u.diagnostic='invalid_result' AND u.phase='verify'
    AND u.validator_version IN ('incremental-validator-v1','incremental-validator-v2') AND j.state='completed'
    AND payload.result IS NOT NULL AND payload.expires_at>now() RETURNING u.id`,[id]);
  if(result.rows.length)await db.query("UPDATE ai_record_updates SET state='running' WHERE id=$1",[id]);
  return result.rows;
 });
 for(const u of units)await enqueueRecordUnit(u.id);
 return units.length;
}
/** Database is the outbox: recover a missed enqueue without requiring the patient to return. */
export async function recoverRecordUpdates(){
 if(!await isRecordDeploymentActive())return 0;
 const parents=await transaction(async db=>{
  const rows=(await db.query(`SELECT id,owner FROM ai_record_updates WHERE stopped=false AND expires_at>now()
    AND state IN ('queued','running','completed_with_withheld_items')
    ORDER BY last_woken_at NULLS FIRST,created_at LIMIT 100 FOR UPDATE SKIP LOCKED`)).rows;
  for(const p of rows)await db.query('UPDATE ai_record_updates SET last_woken_at=now() WHERE id=$1',[p.id]);
  return rows;
 });
 const results=await Promise.allSettled(parents.map(async p=>{
  await revalidateRecordUpdate(p.owner,p.id);await scheduleRecordUpdate(p.id);
 }));
 if(results.some(r=>r.status==='rejected'))throw Error('recovery_incomplete');
 return parents.length;
}

export async function seedRecordRecovery(){
 if(!await isRecordDeploymentActive())return;
 if(process.env.AI_INCREMENTAL_RECORDS_ENABLED!=='true'||process.env.AI_QUEUE_ENABLED!=='true'||process.env.AI_DURABLE_ENABLED!=='true')return;
 await jobQueue.send('health-record-recovery',{id:'00000000-0000-4000-8000-000000000001'},
  {delaySeconds:60,retentionSeconds:86400,idempotencyKey:`record-recovery:${Math.floor(Date.now()/60000)+1}`});
}
