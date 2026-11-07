import type {VercelRequest,VercelResponse} from '@vercel/node';
import {verifyKindeBearer} from '../../_lib/verifyKinde';
import {durableEnabledForOwner} from '../../_lib/pilot';
import {database,transaction,submitWithinTransaction,cancel} from '../../_lib/ledger';
import {advanceStoryOperation} from '../../_lib/story-runtime';
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
  if(req.method==='DELETE'){
   const stopped=await transaction(async db=>{
    await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[owner+id]);
    return (await db.query("INSERT INTO ai_story_operations(owner,id,request_hash,cancelled) VALUES($1,$2,'cancelled',true) ON CONFLICT(owner,id) DO UPDATE SET cancelled=true RETURNING job_id,check_job_id",[owner,id])).rows[0];
   });
   await Promise.all([stopped.job_id,stopped.check_job_id].filter(Boolean).map(j=>cancel(owner,j)));
   return res.json({state:'cancelled'});
  }
  if(req.method==='POST'){
   const input=storyRequest(req.body),hash=digest(JSON.stringify(input));
   await transaction(async db=>{
    await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[owner+id]);
    const old=(await db.query('SELECT request_hash,cancelled FROM ai_story_operations WHERE owner=$1 AND id=$2',[owner,id])).rows[0];
    if(old){if(old.cancelled)return;if(old.request_hash!==hash)throw Error('revision_conflict');return;}
    const job=await submitWithinTransaction(db,owner,storyPayload(input),undefined,'gpt-6-luna','medium');
    await db.query('INSERT INTO ai_story_operations(owner,id,request_hash,request,job_id) VALUES($1,$2,$3,$4,$5)',[owner,id,hash,input,job.id]);
   });
  }else if(!['GET','DELETE'].includes(req.method??''))return res.status(405).end();
  return res.json(await advanceStoryOperation(owner,id));
 }catch(e){const message=(e as Error).message;return res.status((e as any).status===401?401:message==='revision_conflict'?409:message.startsWith('invalid')?422:503).json({error:message==='revision_conflict'?message:'operation_unavailable'});}
}
