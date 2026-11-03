import test from 'node:test';import assert from 'node:assert/strict';
import {makePayload} from '../api/_lib/whole-history-source';
import {artifactFields,artifactPairs,validArtifact} from '../api/_lib/whole-history-artifacts';
import {chainedOverview} from '../api/_lib/whole-history-background';
const template=require('../api/_lib/whole-history-template.json');
const records=[{id:'11111111-1111-4111-8111-111111111111',text:'Synthetic contact at Example Clinic. No diagnosis confirmed.'}];
test('v7 schema only offers category-appropriate fields, with null for medication/care/follow-up',()=>{
 const old=makePayload(records,template,true,true,true,true,true);
 assert.deepEqual(old,makePayload(records,template,true,true,true,true,true,false));
 const fresh=makePayload(records,template,true,true,true,true,true,true);
 assert.equal(JSON.parse(fresh.payload.input).version,'structured-artifact-objects-v7');
 for(const v of fresh.payload.response_format.json_schema.schema.$defs.fact.anyOf){
  assert.equal(v.properties.k.enum.length,1);const k=v.properties.k.enum[0],fields=artifactFields[k];
  if(!fields){assert.deepEqual(v.properties.f,{type:'null'});continue;}
  assert.deepEqual(Object.keys(v.properties.f.properties),fields);
  assert.deepEqual(v.properties.f.required,fields);assert.equal(v.properties.f.additionalProperties,false);
 }
 assert.match(fresh.payload.instructions,/do not omit it or misclassify/);
});
test('object wire encoding and old pairs produce identical grounded overview inputs',()=>{
 const object=Object.fromEntries(artifactFields.practitionerContact.map(k=>[k,k==='organization'?'Example Clinic':null]));
 const payload=makePayload(records,template,true,true,true,true,true,true).payload;
 payload.input=JSON.stringify({...JSON.parse(payload.input),serverOverview:true});
 const proposal=(f:any)=>({concerns:[{id:'c1',name:'Investigation',systems:['other'],evidence:['r1.p1']}],overview:[],passages:{'r1.p1':[{k:'practitionerContact',s:'reported',v:['No diagnosis confirmed.','',''],c:[],p:null,g:['c1'],m:null,f}]}});
 const old=chainedOverview(payload,JSON.stringify(proposal([['organization','Example Clinic']])),'parent');
 const fresh=chainedOverview(payload,JSON.stringify(proposal(object)),'parent');
 assert.deepEqual(old,fresh);assert.match(fresh.instructions,/45–65 words/);
 assert.deepEqual(artifactPairs(object,'practitionerContact'),[['organization','Example Clinic']]);
 assert.equal(validArtifact({...object,result:'Unsupported field'},'practitionerContact'),false);
 for(const k of ['medications','carePlan','followUp'])assert.equal(validArtifact([['name','Synthetic'] ],k),false);
 assert.throws(()=>chainedOverview(payload,JSON.stringify(proposal([['result','Synthetic']])),'parent'),/invalid_proposal/);
});
