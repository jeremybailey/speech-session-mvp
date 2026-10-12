// Isolated, expiring diagnostic deployment only. Never install as a production route.
import type { VercelRequest,VercelResponse } from '@vercel/node';
import { createHash,timingSafeEqual } from 'node:crypto';
import { database,transaction,submitWithinTransaction,validatePayload } from './_lib/ledger';
import { runJob } from './_lib/worker';
import { summaryModelPolicy,conditionModel,conditionReasoning } from './_lib/model-policy';
import { submitConditionWorkflow,conditionWorkflowStatus,prepareConditionStep,finishConditionStep } from './_lib/condition-workflow-store';
import { runDecisionBenchmark } from '../scripts/decisions-benchmark';
const config=require('./config.json');
export default async function handler(req:VercelRequest,res:VercelResponse) {
 res.setHeader('Cache-Control','no-store');
 const supplied=createHash('sha256').update(String(req.headers.authorization??'').replace(/^Bearer /,'')).digest();
 if(!timingSafeEqual(supplied,Buffer.from(config.tokenHash,'hex')) || (Date.now()>config.expiresAt && req.body?.action!=='purge')) return res.status(401).json({error:'unauthorized'});
 if(req.method!=='POST')return res.status(405).end();
 const b=req.body??{};
 if(typeof b.run!=='string'||! /^(baseline|parallel|hybrid|combined|shadow|controls)-[1-3]$/.test(b.run))return res.status(400).json({error:'invalid_run'});
 const owner=config.prefix+(config.runVersion??'')+b.run;
 const uuid=(s:unknown)=>typeof s==='string'&&/^[0-9a-f-]{36}$/i.test(s);
 async function job(id:string){return (await database().query(`SELECT j.id,j.state,j.stage,j.cost_nusd,j.reserve_nusd,j.input_tokens,j.output_tokens,j.created_at,j.started_at,j.finished_at,
 CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END result FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.owner=$1 AND j.id=$2`,[owner,id])).rows[0];}
 try{
  if(b.action==='status')return res.json({jobs:(await database().query("SELECT j.id,j.owner,j.state,j.stage,j.cost_nusd,j.reserve_nusd,j.input_tokens,j.output_tokens,j.created_at,j.started_at,j.finished_at,(p.result->>'providerSeconds')::double precision AS provider_seconds FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE left(j.owner,length($1))=$1 ORDER BY j.created_at",[config.prefix])).rows,
   budget:(await database().query('SELECT limit_nusd,used_nusd,reserved_nusd FROM ai_budgets WHERE id=$1',[process.env.AI_BUDGET_ID])).rows[0],conditionModel:conditionModel(),conditionReasoning:conditionReasoning()});
  if(b.action==='purge')return res.json(await transaction(async db=>{
    // Stop only this experiment's undispatched work, retaining accounting for uncertain charges.
    await db.query('SELECT id FROM ai_budgets WHERE id=$1 FOR UPDATE',[process.env.AI_BUDGET_ID]);
    const jobs=(await db.query('SELECT * FROM ai_jobs WHERE left(owner,length($1))=$1 FOR UPDATE',[config.prefix])).rows;
    if(jobs.some(j=>j.state==='running'))throw Error('benchmark_jobs_active');
    for(const j of jobs.filter(j=>j.state==='queued')){
      await db.query("UPDATE ai_jobs SET state='cancelled',cost_nusd=0,finished_at=now() WHERE id=$1",[j.id]);
      await db.query('UPDATE ai_budgets SET reserved_nusd=reserved_nusd-$2 WHERE id=$1',[j.budget_id,j.reserve_nusd]);
    }
    await db.query("UPDATE ai_condition_workflows SET state='cancelled',finished_at=now(),current_step=NULL WHERE left(owner,length($1))=$1 AND state IN ('queued','running')",[config.prefix]);
    await db.query('DELETE FROM ai_payloads p USING ai_jobs j WHERE p.job_id=j.id AND left(j.owner,length($1))=$1',[config.prefix]);
    await db.query('DELETE FROM ai_condition_workflow_payloads p USING ai_condition_workflows w WHERE p.workflow_id=w.id AND left(w.owner,length($1))=$1',[config.prefix]);
    await db.query('DELETE FROM ai_condition_upload_parts WHERE left(owner,length($1))=$1',[config.prefix]);
    return (await db.query(`SELECT (SELECT count(*) FROM ai_payloads p JOIN ai_jobs j ON j.id=p.job_id WHERE left(j.owner,length($1))=$1)::int job_payloads,
     (SELECT count(*) FROM ai_condition_workflow_payloads p JOIN ai_condition_workflows w ON w.id=p.workflow_id WHERE left(w.owner,length($1))=$1)::int workflow_payloads,
     (SELECT count(*) FROM ai_condition_upload_parts WHERE left(owner,length($1))=$1)::int upload_parts`,[config.prefix])).rows[0];
  }));
  if(process.env.AI_DURABLE_ENABLED!=='true'||process.env.AI_MOCK_INFERENCE==='true')throw Error('pilot_unavailable');
  if(b.action==='decisions')return res.json(await runDecisionBenchmark(owner,b.payload,config.prefix));
  if(b.action==='submit'){
   const payload=validatePayload({...b.payload,workload_type:'development'}),policy=summaryModelPolicy(payload.stage);
   return res.json(await transaction(db=>submitWithinTransaction(db,owner,payload,undefined,policy.model,policy.effort)));
  }
  if(b.action==='job'||b.action==='run'){
   if(!uuid(b.id)||!await job(b.id))return res.status(404).json({error:'not_found'});
   if(b.action==='run')await runJob(b.id);
   return res.json(await job(b.id));
  }
  if(b.action==='condition-submit')return res.json(await submitConditionWorkflow(owner,{...b.payload,workload_type:'development'}));
  if(b.action==='condition-step'&&uuid(b.id)){
   if(!await conditionWorkflowStatus(owner,b.id))return res.status(404).json({error:'not_found'});
   const child=await prepareConditionStep(b.id);if(child){await runJob(child);await finishConditionStep(b.id,child);}
   return res.json(await conditionWorkflowStatus(owner,b.id));
  }
  throw Error('invalid_request');
 }catch(e){const message=(e as Error).message;const safe=['experiment_budget_exhausted','budget_exhausted','budget_configuration_changed','benchmark_jobs_active','invalid_request','invalid_schema','invalid_decision_request','job_running','condition_step_pending'];return res.status(503).json({error:safe.includes(message)?message:'benchmark_unavailable'});}
}
