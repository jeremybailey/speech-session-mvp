// Expiring private phone test only. Never assign a production domain.
import type {VercelRequest,VercelResponse} from '@vercel/node';
import {createHash,timingSafeEqual} from 'node:crypto';
import {database,transaction,submitWithinTransaction,validatePayload,cancel} from './_lib/ledger';
import {runJob} from './_lib/worker';
import {makePayload} from '../scripts/phone-contract';
import {makeOverviewPayload} from '../scripts/phone-overview';
const config=require('./config.json'),template=require('./phone-contract.json');
export default async function handler(req:VercelRequest,res:VercelResponse){
 res.setHeader('Cache-Control','no-store');
 const supplied=createHash('sha256').update(String(req.headers.authorization??'').replace(/^Bearer /,'')).digest();
 if(!timingSafeEqual(supplied,Buffer.from(config.tokenHash,'hex'))||Date.now()>config.expiresAt)return res.status(401).json({error:'trial_expired_or_unauthorized'});
 if(req.method!=='POST')return res.status(405).end();
 const b=req.body??{};if(typeof b.run!=='string'||! /^[0-9a-f-]{36}$/i.test(b.run))return res.status(400).json({error:'invalid_run'});
 const owner=config.prefix+config.runVersion+'phone:'+b.run;
 const job=async(id:string)=>(await database().query(`SELECT j.id,j.state,j.cost_nusd,j.reserve_nusd,j.created_at,j.started_at,j.finished_at,CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END result FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.owner=$1 AND j.id=$2`,[owner,id])).rows[0];
 try{
  if(b.action==='prepare'||b.action==='prepareOverview'){
   if(process.env.AI_DURABLE_ENABLED!=='true'||process.env.AI_MOCK_INFERENCE==='true')throw Error('pilot_unavailable');
   const narrative=b.action==='prepareOverview';
   const built=narrative?makeOverviewPayload(b.records,b.proposal,template):makePayload(b.records,template);
   const {payload}=built; const table='table' in built?built.table:undefined;
   const submitted=await transaction(db=>submitWithinTransaction(db,owner,validatePayload({...payload,workload_type:'development'}),undefined,narrative?'gpt-4o-mini':'gpt-6-luna',narrative?'low':'medium'));
   return res.json({...submitted,locators:table,version:narrative?'b-narrative-pass-v1':template.version,expiresAt:config.expiresAt});
  }
  if(!['job','run','cancel','forget'].includes(b.action)||typeof b.id!=='string'||! /^[0-9a-f-]{36}$/i.test(b.id)||!await job(b.id))return res.status(404).json({error:'not_found'});
  if(b.action==='cancel')await cancel(owner,b.id);
  if(b.action==='run')await runJob(b.id);
  if(b.action==='forget'){
   const j=await job(b.id);if(['running','queued'].includes(j.state))throw Error('job_active');
   await database().query('DELETE FROM ai_payloads WHERE job_id=$1',[b.id]);return res.json({forgotten:true});
  }
  return res.json(await job(b.id));
 }catch(e){const message=(e as Error).message;const safe=['experiment_budget_exhausted','budget_exhausted','invalid_records','source_hash_mismatch','too_many_passages','context_limit_exceeded','job_running','job_active','invalid_proposal','overview_context_limit'];return res.status(503).json({error:safe.includes(message)?message:'trial_unavailable'});}
}
