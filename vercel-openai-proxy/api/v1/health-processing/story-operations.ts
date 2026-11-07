import type {VercelRequest,VercelResponse} from '@vercel/node';
import {verifyKindeBearer} from '../../_lib/verifyKinde';
import {durableEnabledForOwner} from '../../_lib/pilot';
import {database,transaction,submitWithinTransaction,cancel} from '../../_lib/ledger';
import {enqueueJob} from '../../_lib/queue';
import {isRecordDeploymentActive} from '../../_lib/record-runtime';
import {storyRequest,storyPayload,storyResult} from '../../_lib/story-contract';
import {digest} from '../../_lib/incremental-contract';
export default async function handler(req:VercelRequest,res:VercelResponse){
 res.setHeader('Cache-Control','no-store');
 try{
  const owner=await verifyKindeBearer(req.headers.authorization);
  if(process.env.STORY_LAB_ENABLED!=='true'||!durableEnabledForOwner(owner)||!await isRecordDeploymentActive())return res.status(503).json({error:'experiment_unavailable'});
  const id=req.method==='POST'?req.body?.id:req.query.id;
  if(typeof id!=='string'||!/^[-0-9a-f]{36}$/i.test(id))return res.status(400).json({error:'invalid_id'});
  if(req.method==='POST'){
   const input=storyRequest(req.body),hash=digest(JSON.stringify(input));
   await transaction(async db=>{
    await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[owner+id]);
    const old=(await db.query('SELECT request_hash FROM ai_story_operations WHERE owner=$1 AND id=$2',[owner,id])).rows[0];
    if(old){if(old.request_hash!==hash)throw Error('revision_conflict');return;}
    const job=await submitWithinTransaction(db,owner,storyPayload(input),undefined,'gpt-6-luna','medium');
    await db.query('INSERT INTO ai_story_operations(owner,id,request_hash,request,job_id) VALUES($1,$2,$3,$4,$5)',[owner,id,hash,input,job.id]);
   });
  }else if(!['GET','DELETE'].includes(req.method??''))return res.status(405).end();
  let op=(await database().query('SELECT * FROM ai_story_operations WHERE owner=$1 AND id=$2',[owner,id])).rows[0];
  if(!op)return res.status(404).json({error:'not_found'});
  if(req.method==='DELETE'){
   await database().query('UPDATE ai_story_operations SET cancelled=true WHERE owner=$1 AND id=$2',[owner,id]);
   await Promise.all([op.job_id,op.check_job_id].filter(Boolean).map(j=>cancel(owner,j)));op.cancelled=true;
  }
  if(op.cancelled)return res.json({state:'cancelled'});
  if(!op.request || Date.now()-new Date(op.created_at).getTime()>=7*24*60*60*1000)return res.status(410).json({error:'result_expired'});
  async function job(id:string){return (await database().query('SELECT j.state,CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END AS result FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1 AND j.owner=$2',[id,owner])).rows[0];}
  const first=await job(op.job_id);
  if(first.state==='queued')await enqueueJob(op.job_id);
  if(first.state!=='completed')return res.json({state:first.state});
  if(!first.result)return res.status(410).json({error:'result_expired'});
  const candidate=storyResult(first.result.output,op.request);
  if(!op.check_job_id){await transaction(async db=>{
   const current=(await db.query('SELECT * FROM ai_story_operations WHERE owner=$1 AND id=$2 FOR UPDATE',[owner,id])).rows[0];
   if(current.cancelled||current.check_job_id)return;
   const check=await submitWithinTransaction(db,owner,storyPayload(op.request,candidate),undefined,'gpt-6-luna','medium');
   await db.query('UPDATE ai_story_operations SET check_job_id=$3 WHERE owner=$1 AND id=$2',[owner,id,check.id]);
  });op=(await database().query('SELECT * FROM ai_story_operations WHERE owner=$1 AND id=$2',[owner,id])).rows[0];}
  if(op.cancelled||!op.check_job_id)return res.json({state:'cancelled'});
  const checked=await job(op.check_job_id);
  if(checked.state==='queued')await enqueueJob(op.check_job_id);
  if(checked.state!=='completed')return res.json({state:checked.state});
  if(!checked.result)return res.status(410).json({error:'result_expired'});
  return res.json({state:'completed',result:storyResult(checked.result.output,op.request)});
 }catch(e){const message=(e as Error).message;return res.status((e as any).status===401?401:message==='revision_conflict'?409:message.startsWith('invalid')?422:503).json({error:message==='revision_conflict'?message:'operation_unavailable'});}
}
