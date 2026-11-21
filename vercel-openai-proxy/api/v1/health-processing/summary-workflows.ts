import type {VercelRequest,VercelResponse} from '@vercel/node';
import {verifyKindeBearer} from '../../_lib/verifyKinde';
import {durableEnabledForOwner} from '../../_lib/pilot';
import {database,transaction} from '../../_lib/ledger';
import {uuid,digest} from '../../_lib/summary-workflow';
import {submitSummary,summaryStatus,acknowledgeSummary,cancelSummary,resumeSummary,summariesEnabled,dispatchSummaries} from '../../_lib/summary-workflow-store';
export default async function handler(req:VercelRequest,res:VercelResponse){
 res.setHeader('Cache-Control','no-store');
 try {
 const owner=await verifyKindeBearer(req.headers.authorization);
 const id=req.method==='POST'&&!req.query.id?req.body?.id:req.query.id;
 if(!uuid(id))return res.status(400).json({error:{code:'invalid_id'}});
 // Retrieval, deletion and receipts work even when inference is disabled.
 if(req.method==='PATCH'){
  if(typeof req.body?.digest!=='string'||!/^[a-f0-9]{64}$/.test(req.body.digest))throw Error('receipt_mismatch');
  return res.json(await acknowledgeSummary(owner,id,req.body.digest));
 }
 if(req.method==='DELETE'){
  await database().query('DELETE FROM ai_summary_uploads WHERE owner=$1 AND id=$2',[owner,id]);
  return res.json(await cancelSummary(owner,id));
 }
 if(req.method==='GET'){const result=await summaryStatus(owner,id);return result?res.json(result):res.status(404).json({error:{code:'not_found'}});}
 if(!durableEnabledForOwner(owner)||!summariesEnabled())return res.status(503).json({error:{code:'summary_disabled'}});
 if(req.method==='POST'){
  const result=req.query.id?await resumeSummary(owner,id,req.body?.expectedRevision):await submitSummary(owner,req.body);
  // Publication is best-effort here: the independent outbox sweep is authoritative.
  await dispatchSummaries().catch(()=>{});return res.status(202).json(result);
 }
 if(req.method==='PUT'){
  const {operation,hash,count,part,content}=req.body??{};
  if(!/^[a-f0-9]{64}$/.test(hash)||!Number.isInteger(count)||count<1||count>12)throw Error('invalid_upload');
  const data=await transaction(async db=>{
   await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',['summary:'+owner]);
   if((await db.query('SELECT 1 FROM ai_summary_workflows WHERE owner=$1 AND id=$2 AND received_at IS NOT NULL',[owner,id])).rows.length)throw Error('already_received');
   if((await db.query('SELECT 1 FROM ai_summary_cancellations WHERE owner=$1 AND id=$2',[owner,id])).rows.length)throw Error('cancelled');
   await db.query('INSERT INTO ai_summary_uploads(owner,id,digest,count) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING',[owner,id,hash,count]);
   const row=(await db.query('SELECT * FROM ai_summary_uploads WHERE owner=$1 AND id=$2',[owner,id])).rows[0];
   if(row.digest!==hash||row.count!==count)throw Error('revision_conflict');
   if(new Date(row.expires_at)<=new Date())throw Error('expired');
   if(operation==='part'){
    if(!Number.isInteger(part)||part<0||part>=count||typeof content!=='string'||content.length>320000||Buffer.from(content,'base64').toString('base64')!==content)throw Error('invalid_upload');
    const old=(await db.query('SELECT content FROM ai_summary_upload_parts WHERE owner=$1 AND id=$2 AND part=$3',[owner,id,part])).rows[0];
    if(old&&old.content!==content)throw Error('revision_conflict');
    await db.query('INSERT INTO ai_summary_upload_parts(owner,id,part,content) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING',[owner,id,part,content]);return null;
   }
   if(operation!=='complete')throw Error('invalid_upload');
   const parts=(await db.query('SELECT part,content FROM ai_summary_upload_parts WHERE owner=$1 AND id=$2 ORDER BY part',[owner,id])).rows;
   if(parts.length!==count||parts.some((p:any,i:number)=>p.part!==i))throw Error('incomplete_upload');
   const buffer=Buffer.concat(parts.map((p:any)=>Buffer.from(p.content,'base64')));
   if(buffer.length>2_000_000||digest(buffer.toString('utf8'))!==hash)throw Error('invalid_upload');
   return {text:buffer.toString('utf8'),expiresAt:new Date(row.expires_at)};
  });
  if(!data)return res.json({id,uploaded:true});
  const input=JSON.parse(data.text);if(typeof input.id!=='string')throw Error('invalid_upload');if(input.id.toLowerCase()!==id.toLowerCase())throw Error('revision_conflict');
  const result=await submitSummary(owner,input,data.expiresAt);
  await database().query('DELETE FROM ai_summary_uploads WHERE owner=$1 AND id=$2',[owner,id]);
  await dispatchSummaries().catch(()=>{});return res.status(202).json(result);
 }
 return res.status(405).end();
 }catch(error){const code=(error as Error).message;const known=['revision_conflict','invalid_summary_input','summary_too_large','invalid_upload','incomplete_upload','receipt_mismatch','not_found','expired','summary_disabled','cancelled','already_received'];
 const status=(error as any).status===401?401:code==='not_found'?404:code==='expired'?410:['revision_conflict','receipt_mismatch','cancelled','already_received'].includes(code)?409:code.startsWith('invalid')||code==='summary_too_large'?422:503;
 return res.status(status).json({error:{code:known.includes(code)?code:'summary_unavailable'}});}
}
