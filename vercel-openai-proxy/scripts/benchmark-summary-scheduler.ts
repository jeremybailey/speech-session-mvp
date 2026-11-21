/** Isolated synthetic scheduling benchmark. Never sends clinical text or calls a provider. */
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {database,claim,settle} from '../api/_lib/ledger';
import {submitSummary,runSummary,summaryStatus,acknowledgeSummary} from '../api/_lib/summary-workflow-store';
import {digest,SummaryInput} from '../api/_lib/summary-workflow';
async function main(){
 const url=process.env.SUMMARY_TEST_DATABASE_URL??'';
 assert.match(url,/^postgres(?:ql)?:\/\/[^/]*127\.0\.0\.1:55439\//);
 Object.assign(process.env,{DATABASE_URL:url,AI_DEDUPE_SECRET:'synthetic-test-secret',AI_BUDGET_ID:'summary-test',AI_DURABLE_ENABLED:'true',AI_QUEUE_ENABLED:'true',AI_SUMMARY_WORKFLOWS_ENABLED:'true',AI_SUMMARY_WORKFLOW_KINDS:'practitioner'});
 const results:any[]=[];
 try {
 for(let repeat=0;repeat<3;repeat++)for(const policy of ['baseline','parallel']){
  process.env.AI_SUMMARY_PARALLEL_V2=String(policy==='parallel');
  const owner='scheduler-benchmark-'+randomUUID();
  const input:SummaryInput={id:randomUUID(),contract:'summary-workflow-v1',kind:'practitioner',target:randomUUID(),sourceRevision:'1',publicationRevision:'1',template:'practitioner',pipeline:'compact-v2',evidence:Array.from({length:36},(_,i)=>({id:String(1001+i),text:'Synthetic test source. '.repeat(1000)}))};
  let calls=0;
  const started=performance.now();await submitSummary(owner,input);
  const execute=async(id:string)=>{
   const job=await claim(id);if(!job)return 0;calls++;
   // Identical fixed latency and output for each input in both policies.
   await new Promise(resolve=>setTimeout(resolve,150));
   const schema=job.payload.response_format.json_schema.schema;
   const citation=schema.properties.points.items.properties.citationIDs.items.enum[0];
   const point={heading:'Clinical Snapshot',text:'Finding — synthetic example',citationIDs:[citation],topic:'synthetic',recipient:'unspecified',stance:null,subjectCitation:citation,responseCitation:citation,visitSection:null};
   await settle(id,'completed',{input_tokens:10,output_tokens:50},JSON.stringify({points:[point]}));return 1;
  };
  let status:any;
  for(let iteration=0;iteration<100;iteration++){
   await runSummary(input.id,execute);status=await summaryStatus(owner,input.id);
   if(status.state==='completed')break;
   assert.equal(status.state,'running');
  }
  assert.equal(status.state,'completed');
  results.push({policy,repeat,seconds:Number(((performance.now()-started)/1000).toFixed(3)),calls,total:status.total});
  await acknowledgeSummary(owner,input.id,digest(status.output));
 }
 console.log(JSON.stringify({scope:'Synthetic fixed-latency scheduler only; not real model latency or clinical accuracy',results},null,2));
 }finally{await database().end();}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
