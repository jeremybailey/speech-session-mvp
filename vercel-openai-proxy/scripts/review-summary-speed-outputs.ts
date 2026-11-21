import assert from 'node:assert/strict';
import {database} from '../api/_lib/ledger';
import {qualifierRegressions} from './summary-benchmark-qualifiers';
async function main(){
 if(process.env.FOUNDER_SPEED_REVIEW!=='run')return;
 assert.equal(process.env.VERCEL_PROJECT_ID,'prj_H9I9bkd1KzkiqxAW8grLUb4LQp3n');
 const db=database();try{
 const rows=(await db.query(`SELECT j.owner,j.state,p.payload,p.result FROM ai_jobs j JOIN ai_payloads p ON p.job_id=j.id
 WHERE j.budget_id='founder-speed-merge-20261120-v1' AND j.owner LIKE 'founder-speed-merge-20261120-v1:%'`)).rows;
 const result=rows.map(r=>{
  if(r.state!=='completed')return {case:r.owner,state:r.state};
  const source=JSON.parse(r.payload.input).candidates.flatMap((c:any)=>c.points).map((p:any)=>p.text).join('\n');
  const output=JSON.parse(r.result.output).points.map((p:any)=>p.text).join('\n');
  return {case:r.owner,state:r.state,qualifierRegressions:qualifierRegressions(source,output)};
 });
 console.log('SPEED_QUALIFIER_REVIEW '+JSON.stringify(result));
 const timings=(await db.query(`SELECT w.owner,s.key,s.state,j.reasoning_effort,
 extract(epoch FROM(j.finished_at-j.started_at)) duration_seconds,j.input_tokens,j.output_tokens,
 p.result->'diagnostics'->'reasoningTokens' reasoning_tokens,j.started_at,j.finished_at
 FROM ai_summary_workflows w JOIN ai_summary_steps s ON s.workflow_id=w.id
 JOIN ai_jobs j ON j.id=s.job_id LEFT JOIN ai_payloads p ON p.job_id=j.id
 WHERE w.budget_id IN ('founder-speed-e2e-20261120-v1','founder-speed-combined-20261120-v1','founder-speed-combined-fenced-20261120-v2')
 ORDER BY w.created_at,s.key`)).rows;
 for(const timing of timings)console.log('SPEED_STEP_TIMING '+JSON.stringify(timing));
 const finals=(await db.query(`SELECT w.owner,w.execution_policy,w.state,p.result FROM ai_summary_workflows w
 JOIN ai_summary_payloads p ON p.workflow_id=w.id
 WHERE w.budget_id='founder-speed-combined-fenced-20261120-v2'
 AND w.owner LIKE 'founder-speed-combined-fenced-20261120-v2:%' ORDER BY w.created_at`)).rows;
 for(const row of finals){
  console.log('SPEED_FINAL_STATE '+JSON.stringify({owner:row.owner,policy:row.execution_policy,state:row.state}));
  if(row.state==='completed'&&row.result){
   const points=JSON.parse(row.result).points;
   // Explicitly fictional benchmark output only, printed individually to avoid log truncation.
   for(const point of points)console.log('SPEED_FICTIONAL_POINT '+JSON.stringify({owner:row.owner,...point}));
  }
 }


 }finally{await db.end();}
}
main().catch(()=>{console.error('SPEED_REVIEW_FAILED');process.exitCode=1;});
