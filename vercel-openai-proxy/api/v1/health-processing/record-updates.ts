import type {VercelRequest,VercelResponse} from '@vercel/node';
import {verifyKindeBearer} from '../../_lib/verifyKinde';
import {durableEnabledForOwner} from '../../_lib/pilot';
import {incrementalValidator,createSnapshotUpdate,createRecordUpdate,recordUpdateStatus,scheduleRecordUpdate,stopRecordUpdate} from '../../_lib/incremental-workflow';
export default async function handler(req:VercelRequest,res:VercelResponse){
 res.setHeader('Cache-Control','no-store');
 try{
  const owner=await verifyKindeBearer(req.headers.authorization);
  if(!durableEnabledForOwner(owner)||process.env.AI_INCREMENTAL_RECORDS_ENABLED!=='true'||process.env.AI_QUEUE_ENABLED!=='true')return res.status(503).json({error:'incremental_unavailable'});
  if(req.method!=='POST')return res.status(405).end();
  const b=req.body??{};if(typeof b.id!=='string'||!/^[0-9a-f-]{36}$/i.test(b.id))return res.status(400).json({error:'invalid_run'});
  if(['prepare','prepareOverview'].includes(b.action)&&JSON.stringify(b.release??{}).length>2048)return res.status(400).json({error:'invalid_run'});
  if(b.action==='prepare')await createRecordUpdate(owner,b.id,b.records,{app:b.release??null,backend:process.env.CC_BACKEND_COMMIT||process.env.VERCEL_GIT_COMMIT_SHA||'local',backendSourceDigest:process.env.CC_BACKEND_SOURCE_DIGEST??null,model:'gpt-6-luna',reasoning:'medium',validator:incrementalValidator,migration:11});
  else if(b.action==='prepareOverview')await createSnapshotUpdate(owner,b.id,b.snapshot,{app:b.release??null,backend:process.env.CC_BACKEND_COMMIT||process.env.VERCEL_GIT_COMMIT_SHA||'local',backendSourceDigest:process.env.CC_BACKEND_SOURCE_DIGEST??null,contract:'incremental-records-v1'});
  else if(b.action==='cancel')await stopRecordUpdate(owner,b.id);
  else if(b.action!=='status')return res.status(400).json({error:'invalid_action'});
  const status=await recordUpdateStatus(owner,b.id);
  // Wake existing durable work after an enqueue outage, never reset attempts.
  if(status.state==='running'||status.state==='queued')await scheduleRecordUpdate(b.id);
  return res.json(status);
 }catch(error){if((error as {status?:number}).status===401)return res.status(401).json({error:'unauthorized'});const code=(error as Error).message;return res.status(code==='not_found'?404:code==='result_expired'?410:code==='invalid_records'||code==='invalid_run'?400:503).json({error:['not_found','result_expired','invalid_records','invalid_run'].includes(code)?code:'update_unavailable'});}
}
