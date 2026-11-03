import type {VercelRequest,VercelResponse} from '@vercel/node';
import {verifyKindeBearer} from '../../_lib/verifyKinde';
import {durableEnabledForOwner} from '../../_lib/pilot';
import {database,transaction,submitWithinTransaction,validatePayload,cancel} from '../../_lib/ledger';
import {runJob} from '../../_lib/worker';
import {makePayload} from '../../_lib/whole-history-source';
import {makeOverviewPayload} from '../../_lib/whole-history-overview';
import {enqueueWholeHistory,backgroundState,stopWholeHistory} from '../../_lib/whole-history-background';
import {processingFailure} from '../../_lib/processing-errors';
const template=require('../../_lib/whole-history-template.json');
const uuid=(x:unknown)=>typeof x==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(x);
export default async function handler(req:VercelRequest,res:VercelResponse){
 res.setHeader('Cache-Control','no-store');
 try {
  const owner=await verifyKindeBearer(req.headers.authorization);
  if(!durableEnabledForOwner(owner))return res.status(503).json({error:'pilot_disabled'});
  if(req.method!=='POST')return res.status(405).end();
  const b=req.body??{};if(!uuid(b.run))return res.status(400).json({error:'invalid_run'});
  const job=async(id:string)=>(await database().query(`SELECT j.id,j.state,j.stage,j.cost_nusd,j.reserve_nusd,j.created_at,j.started_at,j.finished_at,p.payload,CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END result FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.owner=$1 AND j.id=$2 AND j.stage IN ('whole-history-generation','whole-history-overview')`,[owner,id])).rows[0];
  if(b.action==='prepare'||b.action==='prepareOverview'){
   if(process.env.AI_MOCK_INFERENCE==='true')throw Error('pilot_unavailable');
   const narrative=b.action==='prepareOverview';
   const built=narrative?makeOverviewPayload(b.records,b.proposal,template,b.briefOverview===true):makePayload(b.records,template,b.structuredMedications===true,b.structuredArtifacts===true,b.aggregatePlans===true,b.briefPlans===true,b.careTitles===true);
   const payload={...built.payload,stage:narrative?'whole-history-overview':'whole-history-generation'};
   // A durable client run distinguishes explicit new work. Repeated submissions of
   // this exact run remain idempotent, including after an unknown network outcome.
   payload.input=JSON.stringify({...JSON.parse(payload.input),requestIdentity:b.run,...(!narrative&&b.serverOverview===true?{serverOverview:true}:{})});
   const submitted=await transaction(db=>submitWithinTransaction(db,owner,validatePayload({...payload,workload_type:'incremental'}),undefined,'gpt-6-luna','medium'));
   if((narrative||b.serverOverview===true)&&submitted.state==='queued')await enqueueWholeHistory(submitted.id);
   return res.json({...submitted,...('table' in built?{locators:built.table}:{}),version:narrative?(b.briefOverview===true?'b-narrative-brief-v7':'b-narrative-compact-v6'):(b.careTitles===true?'structured-care-titles-v6':(b.briefPlans===true?'structured-plans-brief-v5':(b.aggregatePlans===true?'structured-plans-v4':(b.structuredArtifacts===true?'structured-artifacts-v3':(b.structuredMedications===true?'structured-medications-v2':template.version)))))});
  }
  if(!['job','run','cancel','forget'].includes(b.action)||!uuid(b.id)||!await job(b.id))return res.status(404).json({error:'not_found'});
  if(b.action==='cancel'){
   const child=await stopWholeHistory(owner,b.id);
   await cancel(owner,b.id);if(child)await cancel(owner,child);
  }
  if(b.action==='run'){
   const current=await job(b.id);
   if(JSON.parse(current.payload?.input??'{}').serverOverview===true||current.stage==='whole-history-overview')await enqueueWholeHistory(b.id);
   else await runJob(b.id);
  }
  if(b.action==='forget'){
   const current=await job(b.id);if(['queued','running'].includes(current.state))throw Error('job_active');
   await database().query('DELETE FROM ai_payloads WHERE job_id=$1',[b.id]);return res.json({forgotten:true});
  }
  const current=await job(b.id);
  const state=backgroundState(current);
  const {payload,...publicJob}=current; // Never return stored source text in status metadata.
  return res.json({...publicJob,state});
 }catch(error){
  const code=(error as Error).message;
  if(['invalid_records','source_hash_mismatch','too_many_passages','context_limit_exceeded','invalid_proposal','overview_context_limit'].includes(code))return res.status(400).json({error:code});
  const failure=processingFailure(error,'submission');return res.status(failure.status).json({error:failure.code});
 }
}
