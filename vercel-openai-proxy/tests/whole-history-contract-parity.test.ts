import test from 'node:test';
import assert from 'node:assert/strict';
import {makeOverviewPayload} from '../api/_lib/whole-history-overview';
import {assertProviderSchemaLimits,makePayload} from '../api/_lib/whole-history-source';
const corpus=require('./fixtures/whole-history-contract.json');
const template=require('../api/_lib/whole-history-template.json');
for(const c of corpus.cases)test('shared app/server contract: '+c.name,()=>{
 if(c.valid)assert.doesNotThrow(()=>makeOverviewPayload(corpus.records,c.proposal,template));
 else assert.throws(()=>makeOverviewPayload(corpus.records,c.proposal,template),/invalid_proposal/);
});
test('new generation schema constrains lengths, instruction categories and record context',()=>{
 const {payload}=makePayload(corpus.records,template,true,true,true,true,true,true,true);
 const schema=payload.response_format.json_schema.schema;
 for(const [alias,other] of [['r1','r2'],['r2','r1']]){
  for(const [index,v] of schema.$defs['fact_'+alias].anyOf.entries()){
   const shared=schema.$defs.fact.anyOf[index];
   const field=(key:string)=>schema.$defs[shared.properties[key].$ref.split('/').at(-1)];
   assert.ok(field('v').items.maxLength<=360);
   assert.equal(v.properties.v.$ref,`#/$defs/fact_${index}_v`);
   const k=field('k').enum[0];
   if(!['carePlan','followUp','vaccinations','medications','testsAndLabs','practitionerContact'].includes(k))assert.deepEqual(field('p'),{type:'null'});
   const ref=v.properties.c.items.$ref.split('/').at(-1);
   assert.deepEqual(schema.$defs[ref].enum,[alias+'.p1']);
   assert.ok(!schema.$defs[ref].enum.includes(other+'.p1'));
  }
 }
 assert.match(payload.instructions,/Every concern declared/);
});

test('oversized schema is rejected before submission rather than failing in the provider',()=>{
 const records=Array.from({length:60},(_,i)=>({id:String(i).padStart(8,'0')+'-1111-4111-8111-111111111111',text:'Synthetic result.'}));
 assert.throws(()=>makePayload(records,template,true,true,true,true,true,true,true),/context_limit_exceeded/);
 assert.doesNotThrow(()=>assertProviderSchemaLimits({type:'string',enum:Array.from({length:1000},(_,i)=>String(i))}));
 assert.throws(()=>assertProviderSchemaLimits({type:'string',enum:Array.from({length:1001},(_,i)=>String(i))}),/context_limit_exceeded/);
});
