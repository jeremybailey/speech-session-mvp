/** Compare reasoning levels on saved intermediate merges from fictional stress data. */
import assert from 'node:assert/strict';
import {database,transaction,submitWithinTransaction} from '../api/_lib/ledger';
import {runJob} from '../api/_lib/worker';
import {validatePoints} from '../api/_lib/summary-workflow';
const budget='founder-speed-merge-20261120-v1';
async function main(){
 if(process.env.FOUNDER_MERGE_BENCHMARK!=='run')return;
 assert.equal(process.env.VERCEL_PROJECT_ID,'prj_H9I9bkd1KzkiqxAW8grLUb4LQp3n');assert.equal(process.env.VERCEL_ENV,'production');
 const db=database();try{
 const source=(await db.query(`SELECT w.id,p.input,p.plan FROM ai_summary_workflows w JOIN ai_summary_payloads p ON p.workflow_id=w.id
 WHERE w.owner='founder-speed-e2e-20261120-v1:0:3' AND w.budget_id='founder-speed-e2e-20261120-v1'`)).rows[0];assert.ok(source);
 const steps=(await db.query('SELECT s.key,s.output,p.payload FROM ai_summary_steps s LEFT JOIN ai_payloads p ON p.job_id=s.job_id WHERE s.workflow_id=$1',[source.id])).rows;
 const outputs=Object.fromEntries(steps.filter(s=>s.output).map(s=>[s.key,s.output]));
 await db.query('INSERT INTO ai_budgets(id,limit_nusd) VALUES($1,2000000000) ON CONFLICT DO NOTHING',[budget]);
 for(let repetition=0;repetition<3;repetition++)for(const effort of repetition%2?['low','medium']:['medium','low']){
  const results=await Promise.all(['merge:0:0','merge:1:0'].map(async key=>{
   const original=steps.find(s=>s.key===key);assert.ok(original?.output&&original?.payload);
   const step=source.plan.find((s:any)=>s.key===key);
   const owner=`${budget}:${repetition}:${effort}:${key}`;
   const receipt=await transaction(tx=>submitWithinTransaction(tx,owner,original.payload,budget,'gpt-6-luna',effort));
   let job:any;
   for(let poll=0;poll<180;poll++){
    try{await runJob(receipt.id);}catch{}
    job=(await db.query('SELECT j.*,p.result FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1 AND j.owner=$2',[receipt.id,owner])).rows[0];
    if(!['queued','running'].includes(job.state))break;
    await new Promise(resolve=>setTimeout(resolve,1000));
   }
   let valid=false,missing:string[]=[];
   if(job.state==='completed')try{
    const points=validatePoints(job.result?.output,source.input,step,outputs);valid=true;
    const before=step.dependencies.flatMap((k:string)=>outputs[k]).map((p:any)=>p.text).join('\n');
    const after=points.map(p=>p.text).join('\n');
    const concepts=[/vitamin k/i,/sweep/i,/declin/i,/salbutamol/i,/budesonide/i,/montelukast/i,/LDL/i,/4\.8/,/ferritin/i,/levothyroxine/i,/TSH/i,/MRI/i,/physiotherap/i,/transplant/i,/tacrolimus/i,/mycophenolate/i,/penicillin/i,/anaphyla/i,/postpartum/i];
    missing=concepts.filter(p=>p.test(before)&&!p.test(after)).map(String);
   }catch{missing=['invalid_output'];}
   return {key,state:job.state,valid,missing,seconds:(new Date(job.finished_at).getTime()-new Date(job.started_at).getTime())/1000,costUSD:Number(job.cost_nusd)/1e9,reasoningTokens:job.result?.diagnostics?.reasoningTokens??null};
  }));
  console.log('MERGE_BENCHMARK '+JSON.stringify({repetition,effort,results}));
  if(results.some(r=>r.state!=='completed'))throw Error('benchmark_incomplete');
 }
 }finally{await db.end();}
}
main().catch(()=>{console.error('MERGE_BENCHMARK_STOPPED; no replacement dispatched');process.exitCode=1;});
