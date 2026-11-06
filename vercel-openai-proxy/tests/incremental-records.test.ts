import test,{mock} from 'node:test';
import assert from 'node:assert/strict';
import {splitRecords,parseFacts,acceptFacts,usableMedicationName} from '../api/_lib/incremental-contract';
import {recoveryDecision} from '../api/_lib/incremental-workflow';
const unit=splitRecords([{id:'00000000-0000-4000-8000-000000000001',text:'Example 5mg tablet. Take one tablet at night.'}])[0];
const fact={id:'f1',category:'medications',text:'Example tablet prescribed',quote:unit.text,name:'Example',fields:[{key:'strength',value:'5mg'}],status:'prescribed',attribution:'',date:'',conditions:[]};
test('identity is source anchored and independent of generated wording/category',()=>{
 const check=JSON.stringify({decisions:[{id:'f1',supported:true,reason:'',nameSupported:true,supportedFields:['strength'],supportedConditions:[]}],omissions:[]});
 const a=acceptFacts(check,parseFacts(JSON.stringify({facts:[fact]}),unit),unit);
 const b=acceptFacts(check,[{...fact,text:'Different wording'}],unit);
 assert.equal(a.facts[0].occurrenceID,b.facts[0].occurrenceID);
 const dispensing=acceptFacts(check,[{...fact,status:'dispensed'}],unit);
 assert.notEqual(a.facts[0].occurrenceID,dispensing.facts[0].occurrenceID);
});
test('unknown identities withheld but originals and audit candidates survive',()=>{
 const unknown={...fact,name:null};const parsed=parseFacts(JSON.stringify({facts:[unknown]}),unit);
 const result=acceptFacts(JSON.stringify({decisions:[{id:'f1',supported:true,reason:'',nameSupported:true,supportedFields:['strength'],supportedConditions:[]}],omissions:[]}),parsed,unit);
 assert.equal(result.facts.length,0);assert.equal(result.withheld,1);assert.equal(parsed[0].quote,unit.text);
 for(const name of ['','eye drops','unknown product','5','Medication — check original'])assert.equal(usableMedicationName(name),false);
});
test('checker must account for every candidate and cannot invent omission evidence',()=>{
 assert.throws(()=>acceptFacts('{"decisions":[],"omissions":[]}',[fact],unit));
 assert.throws(()=>acceptFacts(JSON.stringify({decisions:[{id:'f1',supported:true}],omissions:['Invented']}),[fact],unit));
 const parsed=parseFacts(JSON.stringify({facts:[{...fact,fields:[{key:'dose',value:'two tablets'}]}]}),unit);
 const result=acceptFacts(JSON.stringify({decisions:[{id:'f1',supported:true,nameSupported:true,supportedFields:['dose'],supportedConditions:[]}],omissions:[]}),parsed,unit);
 assert.equal(result.facts.length,1);assert.deepEqual(result.facts[0].fields,[]);assert.equal(result.withheld,1);
});
test('split sources cover every scalar once and retain neighboring context',()=>{
 const text=('table heading\nExample 5mg row\n').repeat(2000);
 const parts=splitRecords([{id:unit.recordID,text}]);
 assert.equal(parts.map(p=>p.text).join(''),text);assert.ok(parts.length>1);assert.ok(parts[1].context.length>0);
 assert.deepEqual(parts.map(p=>p.key),splitRecords([{id:unit.recordID,text}]).map(p=>p.key));
});
test('recovery reconciles uncertainty before one replacement and bounds all attempts',()=>{
 assert.equal(recoveryDecision('uncertain',1,899999,false),'wait');
 assert.equal(recoveryDecision('uncertain',1,900000,false),'retry');
 assert.equal(recoveryDecision('uncertain',2,900000,true),'block');
 assert.equal(recoveryDecision('incomplete',3,0,false,429),'block');
 assert.equal(recoveryDecision('incomplete',1,0,false,429),'retry');
 assert.equal(recoveryDecision('incomplete',1,0,false,401),'block');
});

test('failed optional relationship and dose do not discard a supported medication identity',()=>{
 const candidate={...fact,conditions:['Unsupported association'],fields:[{key:'dose',value:'one tablet'}]};
 const result=acceptFacts(JSON.stringify({decisions:[{id:'f1',supported:true,nameSupported:true,supportedFields:[],supportedConditions:[],reason:''}],omissions:[]}),[candidate],unit);
 assert.equal(result.facts.length,1);assert.deepEqual(result.facts[0].fields,[]);assert.deepEqual(result.facts[0].conditions,[]);
});

import {validateSnapshot,validateSnapshotOverview} from '../api/_lib/incremental-overview';
test('overview binds citations and numeric claims to the published snapshot',()=>{
 const snapshot=validateSnapshot({fingerprint:'v1',conditionContext:'',facts:[{id:'f1',text:'Example 5mg prescribed; current use unknown.'}]});
 const raw=(text:string,id='f1')=>JSON.stringify({sentences:[{text,factIDs:[id]}]});
 assert.equal(validateSnapshotOverview(raw('Example 5mg was prescribed.'),snapshot).sentences.length,1);
 assert.throws(()=>validateSnapshotOverview(raw('Example 10mg was prescribed.'),snapshot));
 assert.throws(()=>validateSnapshotOverview(raw('Example prescribed.','unpublished'),snapshot));
 assert.throws(()=>validateSnapshot({...snapshot,facts:[snapshot.facts[0],snapshot.facts[0]]}));
});

import {seedRecordRecovery} from '../api/_lib/incremental-workflow';
import {jobQueue} from '../api/_lib/queue';
test('recovery heartbeat is delayed, deduplicated, and stops when processing is disabled',async()=>{
 const keys=['AI_INCREMENTAL_RECORDS_ENABLED','AI_QUEUE_ENABLED','AI_DURABLE_ENABLED'];
 const prior=keys.map(k=>process.env[k]);const calls:any[]=[];
 mock.method(jobQueue,'send',async(...args:any[])=>{calls.push(args);return {messageId:'synthetic'};});
 mock.method(Date,'now',()=>60000);
 try {
  for(const k of keys)process.env[k]='true';
  await seedRecordRecovery();await seedRecordRecovery();
  assert.equal(calls[0][0],'health-record-recovery');assert.equal(calls[0][2].delaySeconds,60);
  assert.equal(calls[0][2].idempotencyKey,calls[1][2].idempotencyKey);
  process.env.AI_DURABLE_ENABLED='false';await seedRecordRecovery();assert.equal(calls.length,2);
 } finally {keys.forEach((k,i)=>{if(prior[i]===undefined)delete process.env[k];else process.env[k]=prior[i];});mock.restoreAll();}
});

test('condition navigation systems require independent acceptance and preserve legacy output',()=>{
 const candidate={...fact,conditions:['Eye concern'],conditionSystems:[{name:'Eye concern',system:'eye'}]};
 const check={decisions:[{id:'f1',supported:true,nameSupported:true,supportedFields:['strength'],supportedConditions:['Eye concern'],supportedConditionSystems:['Eye concern']}],omissions:[]};
 assert.deepEqual(acceptFacts(JSON.stringify(check),[candidate],unit).facts[0].conditionSystems,candidate.conditionSystems);
 check.decisions[0].supportedConditionSystems=[];
 const withheld=acceptFacts(JSON.stringify(check),[candidate],unit);
 assert.equal(withheld.facts.length,1);assert.deepEqual(withheld.facts[0].conditions,['Eye concern']);assert.deepEqual(withheld.facts[0].conditionSystems,[]);
 const legacy={...candidate,conditionSystems:undefined};
 assert.deepEqual(acceptFacts(JSON.stringify(check),[legacy],unit).facts[0].conditionSystems,[]);
});

import {parseExtractionBatch} from '../api/_lib/incremental-contract';
test('malformed extraction candidates cannot discard valid source-supported neighbors',()=>{
 const invalid={...fact,id:'bad',quote:'A quotation absent from the source'};
 const batch=parseExtractionBatch(JSON.stringify({facts:[fact,invalid]}),unit);
 assert.deepEqual(batch.facts,[fact]);assert.equal(batch.withheld,1);
 assert.throws(()=>parseFacts(JSON.stringify({facts:[invalid]}),unit));
 const duplicates=parseExtractionBatch(JSON.stringify({facts:[fact,{...fact}]}),unit);
 assert.equal(duplicates.facts.length,0);assert.equal(duplicates.withheld,2);
});
test('nonliteral omission notes remain unresolved without dropping checked facts',()=>{
 const check={decisions:[{id:'f1',supported:true,nameSupported:true,supportedFields:['strength'],supportedConditions:[]}],omissions:['A paraphrased missing detail']};
 const result=acceptFacts(JSON.stringify(check),[fact],unit);
 assert.equal(result.facts.length,1);assert.equal(result.withheld,1);assert.deepEqual(result.omissions,[]);
 check.decisions[0].supported=false;
 assert.equal(acceptFacts(JSON.stringify(check),[fact],unit).facts.length,0);
});

import {isRecordDeploymentActive} from '../api/_lib/record-runtime';
test('superseded deployment cannot keep a recovery heartbeat alive',async()=>{
 const prior=process.env.VERCEL_DEPLOYMENT_ID;
 try{
  process.env.VERCEL_DEPLOYMENT_ID='dpl_old';
  const db={query:async()=>({rows:[{deployment_id:'dpl_current'}]})} as any;
  assert.equal(await isRecordDeploymentActive(db),false);
  process.env.VERCEL_DEPLOYMENT_ID='dpl_current';assert.equal(await isRecordDeploymentActive(db),true);
  assert.equal(await isRecordDeploymentActive({query:async()=>({rows:[]})} as any),false);
 }finally{if(prior===undefined)delete process.env.VERCEL_DEPLOYMENT_ID;else process.env.VERCEL_DEPLOYMENT_ID=prior;}
});
