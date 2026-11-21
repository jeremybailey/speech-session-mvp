/** Founder-only, idempotent, capped evaluation using fictional records only.
 * Run at build time, never expose an HTTP benchmark endpoint. */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {database,transaction,submitWithinTransaction} from '../api/_lib/ledger';
import {runJob} from '../api/_lib/worker';
import {summaryPayload,summaryPlan,validatePoints,SummaryInput} from '../api/_lib/summary-workflow';
const name='founder-speed-20261120-v1';
export const cases=[
 {name:'tentative-newborn',text:'Fictional antenatal visit, 2026-11-10. Pregnant, 37 weeks at this visit. Asked about vitamin K injection for the newborn. Says "I think we are okay with it"; preference remains tentative. Declined a membrane sweep today; may reconsider next week. Next visit booked with Jo on November 17 at 10 am.',required:[/pregnan|37 weeks/i,/vitamin k/i,/tentative|thinks|consider|okay|ok with/i,/sweep/i,/declin/i,/next week|reconsider/i,/november 17|nov 17|17 november|17th|17 nov|2026-11-17/i]},
 {name:'medication-change',text:'Fictional visit, 2026-10-05. Asthma with wheezing during exercise twice weekly. Uses salbutamol as needed. Budesonide was prescribed today but not yet started; wants to ask about side effects. Previously stopped montelukast because of nightmares. Follow-up in four weeks agreed.',required:[/asthma/i,/salbutamol/i,/budesonide/i,/not.*start|unstarted|pending|yet to start/i,/montelukast/i,/nightmare/i,/four weeks|4 weeks/i]},
 {name:'abnormal-labs',text:'Fictional lab review, 2026-09-12. LDL 4.8 mmol/L, above the laboratory reference range, improved from 5.6 mmol/L on 2026-06-10. HbA1c 5.3%, within range. Ferritin 9 ug/L, below range. Oral iron discussed but no decision made. No statin has been prescribed.',required:[/LDL/i,/4\.8/,/improv|down|decreas|lower|↓/i,/ferritin/i,/\b9\b/,/iron/i]},
 {name:'dated-context',text:'Fictional record dated 2026-11-12. Delivered on 2026-10-01; currently six weeks postpartum at this visit. Pregnancy was documented as 31 weeks on 2026-08-12 and is historical. Persistent fatigue. Breastfeeding. Levothyroxine continues for hypothyroidism. TSH check booked for 2026-11-19.',required:[/postpartum/i,/fatigue/i,/breastfeed/i,/levothyroxine/i,/hypothyroid/i,/TSH/i,/19/]},
 {name:'conditional-plan',text:'Fictional orthopaedic visit, 2026-11-04. Left knee pain after running. Declined corticosteroid injection today. MRI deferred unless symptoms persist after six weeks of physiotherapy. Physiotherapy accepted and booked for November 8 with Pat. No surgery planned.',required:[/knee/i,/declin/i,/inject|corticosteroid/i,/MRI/i,/defer|unless|persist|conditional/i,/physiotherap/i,/november 8|nov 8|8 november|8th|8 nov|2026-11-08/i]},
 {name:'transplant-allergy',text:'Fictional review, 2026-11-06. Kidney transplant recipient, taking tacrolimus and mycophenolate. Penicillin allergy caused anaphylaxis. New persistent dry cough for two weeks. Chest X-ray booked for tomorrow. No fever reported. No antibiotic prescribed; waiting for assessment.',required:[/transplant/i,/tacrolimus/i,/mycophenolate/i,/penicillin/i,/anaphyla/i,/cough/i,/x.?ray/i]}
];
const uid=(value:string)=>{const x=createHash('sha256').update(value).digest('hex').slice(0,32);return `${x.slice(0,8)}-${x.slice(8,12)}-${x.slice(12,16)}-${x.slice(16,20)}-${x.slice(20)}`;};
async function main(){
 if(process.env.FOUNDER_PROVIDER_BENCHMARK!=='run')return;
 assert.equal(process.env.VERCEL_PROJECT_ID,'prj_H9I9bkd1KzkiqxAW8grLUb4LQp3n');
 assert.equal(process.env.VERCEL_ENV,'production');
 assert.equal(process.env.AI_WHOLE_HISTORY_PROVIDER_BACKGROUND,'true');
 const db=database();
 try {
  await db.query('INSERT INTO ai_budgets(id,limit_nusd) VALUES($1,2000000000) ON CONFLICT DO NOTHING',[name]);
  for(let repetition=0;repetition<3;repetition++)for(const concurrency of repetition%2?[6,3]:[3,6]){
   let cursor=0;const rows:any[]=[];
   await Promise.all(Array.from({length:concurrency},async()=>{
    for(;;){const index=cursor++;if(index>=cases.length)return;const fixture=cases[index];
     const owner=`${name}:${repetition}:${concurrency}:${index}`;
     const input:SummaryInput={id:uid(owner),contract:'summary-workflow-v1',kind:'practitioner',template:'practitioner',target:owner,sourceRevision:'fictional-1',publicationRevision:'empty',pipeline:'compact-v2',evidence:[{id:'fictional-1',text:fixture.text}]};
     const step=summaryPlan(input)[0],payload=summaryPayload(input,step,{},0);
     const receipt=await transaction(tx=>submitWithinTransaction(tx,owner,payload,name,'gpt-6-luna','medium'));
     let job:any;
     for(let poll=0;poll<180;poll++){
      try{await runJob(receipt.id);}catch{/* Pending responses are collected; never dispatch a replacement. */}
      job=(await db.query('SELECT j.state,j.started_at,j.finished_at,j.cost_nusd,j.input_tokens,j.output_tokens,p.result FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1 AND j.owner=$2',[receipt.id,owner])).rows[0];
      if(job.state!=='queued'&&job.state!=='running')break;
      await new Promise(resolve=>setTimeout(resolve,1000));
     }
     let format=false,missing:string[]=[];
     if(job.state==='completed')try{
      const points=validatePoints(job.result?.output,input,step,{});format=true;
      const text=points.map(p=>p.text).join('\n');missing=fixture.required.filter(pattern=>!pattern.test(text)).map(String);
     }catch{missing=['invalid_output'];}
     rows.push({fixture:fixture.name,state:job.state,format,missing,costUSD:Number(job.cost_nusd)/1e9,inputTokens:Number(job.input_tokens),outputTokens:Number(job.output_tokens),start:job.started_at,end:job.finished_at});
    }
   }));
   const elapsed=(Math.max(...rows.map(r=>new Date(r.end).getTime()))-Math.min(...rows.map(r=>new Date(r.start).getTime())))/1000;
   console.log('PROVIDER_BENCHMARK '+JSON.stringify({repetition,concurrency,seconds:elapsed,costUSD:rows.reduce((n,r)=>n+r.costUSD,0),cases:rows}));
   if(rows.some(r=>r.state!=='completed'))throw Error('benchmark_incomplete');
  }
 }finally{await db.end();}
}
main().catch(()=>{console.error('PROVIDER_BENCHMARK_STOPPED; results and reservations retained; no automatic replacement');process.exitCode=1;});
