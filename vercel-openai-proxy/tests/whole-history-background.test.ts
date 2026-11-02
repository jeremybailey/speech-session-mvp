import test from 'node:test';
import assert from 'node:assert/strict';
import {chainedOverview,backgroundState,wholeHistoryTopic,runWholeHistory} from '../api/_lib/whole-history-background';
import {makePayload} from '../api/_lib/whole-history-source';
import {requestHash} from '../api/_lib/ledger';
import {readFileSync} from 'node:fs';
const template=require('../api/_lib/whole-history-template.json');
const records=[{id:'11111111-1111-4111-8111-111111111111',text:'Synthetic patient reports headache.'}];
const proposal={concerns:[{id:'c1',name:'Headache',systems:['neurological'],evidence:['r1.p1']}],overview:[{text:'You report headaches.',cite:['r1.p1']}],passages:{'r1.p1':[{k:'symptoms',s:'reported',v:['Headache','patient',''],c:[],p:null,g:['c1']}]}};
function parentPayload(){const p=makePayload(records,template).payload;p.input=JSON.stringify({...JSON.parse(p.input),serverOverview:true});return p;}
test('server constructs the same overview from retained originals without a phone handoff',()=>{
 const payload=chainedOverview(parentPayload(),JSON.stringify(proposal),'parent-run');
 assert.equal(payload.stage,'whole-history-overview');
 const input=JSON.parse(payload.input);
 assert.equal(input.requestIdentity,'parent-run');
 assert.equal(input.facts[0].text,'Headache');
 assert.deepEqual(input.facts[0].conditionIDs,['c1']);
 assert.throws(()=>chainedOverview(parentPayload(),JSON.stringify({...proposal,passages:{}}),'parent-run'),/invalid_proposal/);
 assert.throws(()=>chainedOverview(parentPayload(),'truncated {','parent-run'),/invalid_proposal/);
});
test('queue redelivery and phone status polling cannot change the child request identity',()=>{
 process.env.AI_DEDUPE_SECRET='synthetic-background-dedupe';
 const first=chainedOverview(parentPayload(),JSON.stringify(proposal),'parent-run');
 const second=chainedOverview(parentPayload(),JSON.stringify(proposal),'parent-run');
 assert.equal(requestHash('owner',first,'gpt-6-luna','medium'),requestHash('owner',second,'gpt-6-luna','medium'));
 assert.notEqual(requestHash('other-owner',first,'gpt-6-luna','medium'),requestHash('owner',first,'gpt-6-luna','medium'));
});
test('generation completion stays pending until overview receipt is durable; stopped and failed outcomes stay terminal',()=>{
 const job={stage:'whole-history-generation',state:'completed',payload:parentPayload(),result:{output:JSON.stringify(proposal)}};
 assert.equal(backgroundState(job),'running');
 assert.equal(backgroundState({...job,result:{...job.result,overviewJobID:'child'}}),'completed');
 assert.equal(backgroundState({...job,payload:{...job.payload,whole_history_stop:true}}),'cancelled');
 assert.equal(backgroundState({...job,result:{overview_error:'budget_exhausted'}}),'failed');
 assert.equal(backgroundState({...job,state:'uncertain'}),'uncertain');
 assert.equal(backgroundState({...job,payload:{input:'{}'}}),'completed','Older clients keep their existing protocol');
});
test('long B requests use the private queue with a bounded worker duration',()=>{
 const config=JSON.parse(readFileSync(new URL('../vercel.json',import.meta.url),'utf8'));
 const route=config.functions['api/v1/health-processing/queue.ts'];
 assert.equal(route.maxDuration,300);
 assert.equal(route.experimentalTriggers[0].type,'queue/v2beta');
 assert.equal(route.experimentalTriggers[0].topic,wholeHistoryTopic);
});

function harness(stopped=false,uncertain=false,failPublishOnce=false){
 const parent:any={owner:'synthetic-owner',state:'queued',payload:{...parentPayload(),...(stopped?{whole_history_stop:true}:{})},result:null};
 let submissions=0,dispatches=0;const queued:string[]=[];
 const db={async query(sql:string,args:any[]){
  if(sql.startsWith('SELECT j.stage'))return{rows:[{stage:'whole-history-generation',payload:parent.payload}]};
  if(sql.startsWith('SELECT j.owner'))return{rows:[parent]};
  if(sql.startsWith('UPDATE ai_payloads SET result')){parent.result={...parent.result,...JSON.parse(args[1])};return{rows:[]};}
  throw Error('Unexpected synthetic database query');
 }};
 const runtime:any={database:()=>db,transaction:async(fn:any)=>fn(db),runJob:async()=>{
  if(parent.state==='queued'){dispatches++;parent.state=uncertain?'uncertain':'completed';parent.result={output:JSON.stringify(proposal)};}
 },submitWithinTransaction:async()=>{submissions++;return{id:'child-id',state:'queued'};},enqueueWholeHistory:async(id:string)=>{
  if(failPublishOnce){failPublishOnce=false;throw Error('temporary_queue_failure');}queued.push(id);
 }};
 return{runtime,parent,queued,counts:()=>({submissions,dispatches})};
}
test('server completes both handoffs with no phone; redelivery reuses the durable child',async()=>{
 const h=harness();await runWholeHistory('parent-id',h.runtime);await runWholeHistory('parent-id',h.runtime);
 assert.deepEqual(h.counts(),{submissions:1,dispatches:1});
 assert.equal(h.parent.result.overviewJobID,'child-id');assert.deepEqual(h.queued,['child-id','child-id']);
});
test('child publication failure retries delivery without a second reservation or inference',async()=>{
 const h=harness(false,false,true);await assert.rejects(runWholeHistory('parent-id',h.runtime));
 assert.equal(h.parent.result.overviewJobID,'child-id');await runWholeHistory('parent-id',h.runtime);
 assert.deepEqual(h.counts(),{submissions:1,dispatches:1});assert.deepEqual(h.queued,['child-id']);
});
test('Stop and an uncertain generation never initiate a paid overview',async()=>{
 for(const h of [harness(true),harness(false,true)]){
  await runWholeHistory('parent-id',h.runtime);assert.equal(h.counts().submissions,0);assert.deepEqual(h.queued,[]);
 }
});
test('an exhausted overview allowance is terminal and never resubmits on queue redelivery',async()=>{
 const h=harness();let attempts=0;
 h.runtime.submitWithinTransaction=async()=>{attempts++;throw Error('budget_exhausted');};
 await runWholeHistory('parent-id',h.runtime);await runWholeHistory('parent-id',h.runtime);
 assert.equal(attempts,1);assert.equal(h.parent.result.overview_error,'budget_exhausted');assert.deepEqual(h.queued,[]);
});
