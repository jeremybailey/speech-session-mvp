/** Full durable workflow stress test, fictional repeated documents only. */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {cases} from './benchmark-summary-provider';
import {database} from '../api/_lib/ledger';
import {submitSummary,runSummary,summaryStatus,acknowledgeSummary} from '../api/_lib/summary-workflow-store';
import {digest,SummaryInput} from '../api/_lib/summary-workflow';
const name='founder-speed-e2e-20261120-v1';
const uid=(value:string)=>{const x=createHash('sha256').update(value).digest('hex').slice(0,32);return `${x.slice(0,8)}-${x.slice(8,12)}-${x.slice(12,16)}-${x.slice(16,20)}-${x.slice(20)}`;};
async function main(){
 if(process.env.FOUNDER_E2E_BENCHMARK!=='run')return;
 assert.equal(process.env.VERCEL_PROJECT_ID,'prj_H9I9bkd1KzkiqxAW8grLUb4LQp3n');assert.equal(process.env.VERCEL_ENV,'production');
 Object.assign(process.env,{AI_SUMMARY_WORKFLOWS_ENABLED:'true',AI_SUMMARY_WORKFLOW_KINDS:'practitioner',AI_BUDGET_ID:name});
 const db=database();try{
 await db.query('INSERT INTO ai_budgets(id,limit_nusd) VALUES($1,3000000000) ON CONFLICT DO NOTHING',[name]);
 for(let repetition=0;repetition<3;repetition++)for(const concurrency of repetition%2?[6,3]:[3,6]){
  process.env.AI_SUMMARY_PARALLEL_V2=String(concurrency===6);
  const owner=`${name}:${repetition}:${concurrency}`;
  const evidence=Array.from({length:36},(_,index)=>{
   let text=cases[index%cases.length].text;
   if(index%cases.length===0)text=text.replace('2026-11-10','2026-09-10');
   // Repetition deliberately exercises duplicate-topic merging across batches.
   return {id:`fictional-${index}`,text:Array.from({length:Math.floor(22000/(text.length+1))},()=>text).join('\n')};
  });
  const input:SummaryInput={id:uid(owner),contract:'summary-workflow-v1',kind:'practitioner',template:'practitioner',target:owner,sourceRevision:'fictional-1',publicationRevision:'empty',pipeline:'compact-v2',evidence};
  await submitSummary(owner,input);
  let status:any;
  for(let poll=0;poll<600;poll++){
   await runSummary(input.id);status=await summaryStatus(owner,input.id);
   if(poll%10===0)console.log('E2E_PROGRESS '+JSON.stringify({repetition,concurrency,state:status.state,completed:status.completed,total:status.total}));
   if(!['queued','running','retry_scheduled'].includes(status.state))break;
   await new Promise(resolve=>setTimeout(resolve,1500));
  }
  const stats=(await db.query(`SELECT w.state,w.calls,w.error_code,extract(epoch FROM(max(j.finished_at)-min(j.started_at))) seconds,
   sum(j.cost_nusd)::text cost_nusd,count(*) FILTER(WHERE j.state<>'completed')::int noncompleted
   FROM ai_summary_workflows w JOIN ai_summary_children c ON c.workflow_id=w.id JOIN ai_jobs j ON j.id=c.job_id
   WHERE w.id=$1 AND w.owner=$2 GROUP BY w.id`,[input.id,owner])).rows[0];
  if(status.state==='completed'&&!status.output)throw Error('benchmark_payloads_already_purged');
  let missing:string[]=[];
  if(status.output){const result=JSON.parse(status.output);const text=result.points.map((p:any)=>p.text).join('\n');
   const required=[/postpartum/i,/vitamin k/i,/tentative|think|consider|okay/i,/sweep/i,/declin/i,/reconsider|next week/i,/salbutamol/i,/budesonide/i,/montelukast/i,/LDL/i,/4\.8/,/ferritin/i,/levothyroxine/i,/TSH/i,/MRI/i,/physiotherap/i,/transplant/i,/tacrolimus/i,/mycophenolate/i,/penicillin/i,/anaphyla/i];
   missing=required.filter(p=>!p.test(text)).map(String);
  }
  console.log('E2E_RESULT '+JSON.stringify({repetition,concurrency,...stats,missing}));
  if(status.state!=='completed')throw Error('benchmark_incomplete');
  // Keep fictional results until all repeated build phases have finished. Cleanup is explicit.
 }
 }finally{await db.end();}
}
main().catch(()=>{console.error('E2E_BENCHMARK_STOPPED; saved work retained, no replacement');process.exitCode=1;});
