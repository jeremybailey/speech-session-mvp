import test from 'node:test';
import assert from 'node:assert/strict';
import {makePayload} from '../api/_lib/whole-history-source';
import {makeOverviewPayload} from '../api/_lib/whole-history-overview';
import {artifactFields} from '../api/_lib/whole-history-artifacts';
const template=require('../api/_lib/whole-history-template.json');
const records=[{id:'11111111-1111-4111-8111-111111111111',text:'Synthetic patient reports dizziness. Serum potassium 4.2 mmol/L. Follow up in two weeks.'}];
test('shared category contract keeps typed fields and accepts unknown attribution/timing',()=>{
 const result=makePayload(records,template,true,true,true,true,true,true,true,true,true);
 const schema=result.payload.response_format.json_schema.schema;
 assert.equal(JSON.parse(result.payload.input).version,'category-uniform-fields-scoped-v19');
 assert.equal(schema.$defs.fact.anyOf.length,12);
 assert.ok(schema.$defs.fact_r1);
 const get=(v:any,k:string)=>schema.$defs[v.properties[k].$ref.split('/').at(-1)];
 for(const v of schema.$defs.fact.anyOf){
  const k=get(v,'k').enum[0];
  assert.ok(new RegExp(get(v,'v').items.pattern).test(''));
  const p=get(v,'p');for(const plan of (p.anyOf??[p]).filter((p:any)=>p.type==='object'))for(const key of ['a','t','q'])assert.ok(new RegExp(plan.properties[key].pattern).test(''));
  const f=get(v,'f');if(artifactFields[k]){assert.deepEqual(f.required.filter((key:string)=>!key.startsWith('_pad')),artifactFields[k]);assert.equal(f.required.length,7);}else assert.equal(f.type,'null');
 }
 assert.match(result.payload.instructions,/CATEGORY DECISION v12/);
 assert.match(result.payload.instructions,/VACCINE \/ ALLERGY DISTINCTION/);
 assert.match(result.payload.instructions,/SAME original record/);
});
test('runtime contract still enforces category membership, citations and instruction semantics',()=>{
 const proposal=(k:string,f:any)=>({concerns:[{id:'c1',name:'Synthetic',systems:['unknown'],evidence:['r1.p1']}],overview:[{text:'Synthetic.',cite:['r1.p1']}],passages:{'r1.p1':[{k,s:'reported',v:['Synthetic','',''],c:[],p:null,g:['c1'],m:null,f}]}});
 for(const k of Object.keys(artifactFields))assert.doesNotThrow(()=>makeOverviewPayload(records,proposal(k,Object.fromEntries(artifactFields[k].map(key=>[key,null]))),template));
 assert.throws(()=>makeOverviewPayload(records,proposal('symptoms',[['result','4.2']]),template),/invalid_proposal/);
 assert.throws(()=>makeOverviewPayload(records,proposal('carePlan',null),template),/invalid_proposal/);
 const invalid=proposal('symptoms',[]);invalid.overview[0].cite=['r9.p1'];
 assert.throws(()=>makeOverviewPayload(records,invalid,template),/invalid_proposal/);
});
test('balanced field sharing supports the 60-record schema that exceeds v9 object-property limits',()=>{
 const larger=Array.from({length:60},(_,i)=>({id:String(i).padStart(8,'0')+'-1111-4111-8111-111111111111',text:'Synthetic result.'}));
 assert.throws(()=>makePayload(larger,template,true,true,true,true,true,true,true),/context_limit_exceeded/);
 assert.throws(()=>makePayload(larger,template,true,true,true,true,true,true,true,true,true),/context_limit_exceeded/);
 assert.doesNotThrow(()=>makePayload(larger,template,true,true,true,true,true,true,true,true));
});

test('frozen live synthetic output passes the same runtime validator',()=>{
 const corpus=require('./fixtures/whole-history-balanced-synthetic.json');
 assert.doesNotThrow(()=>makeOverviewPayload(corpus.records,corpus.proposal,template,true));
});

test('shared definitions avoid repeating the category union for every source record',()=>{
 const corpus=require('./fixtures/whole-history-balanced-synthetic.json');
 const old=makePayload(corpus.records,template,true,true,true,true,true,true,true);
 const candidate=makePayload(corpus.records,template,true,true,true,true,true,true,true,true,true);
 assert.ok(JSON.stringify(candidate.payload).length<JSON.stringify(old.payload).length*1.5);
 const schema=candidate.payload.response_format.json_schema.schema;
 for(const [id,shape] of Object.entries(schema.properties.passages.properties) as any[])assert.equal(shape.anyOf.find((v:any)=>v.type==='array').items.$ref,'#/$defs/fact_'+id.split('.')[0]);
 assert.equal(schema.properties.concerns.minItems,0);
});

test('temporal-context replay retains both sides of changes without inventing test results',()=>{
 const frozen=require('./fixtures/whole-history-temporal-context-result.json');
 assert.doesNotThrow(()=>makeOverviewPayload(frozen.records,frozen.proposal,template,true));
 const rows=(n:number)=>frozen.proposal.passages[`r${n}.p1`];
 const contexts=(n:number)=>rows(n).filter((f:any)=>f.k==='biopsychosocialContext').map((f:any)=>JSON.stringify(f)).join(' ');
 assert.match(contexts(1),/no time to continue/);assert.match(contexts(1),/stopped working/);assert.match(contexts(1),/more time for appointments/);
 assert.match(contexts(2),/previously unaffordable/);assert.match(contexts(2),/relative now provides rides/);
 assert.match(contexts(3),/used to work nights/);assert.match(contexts(3),/now work daytime shifts/);assert.match(contexts(3),/five hours/);
 assert.match(contexts(4),/now has childcare help/);assert.match(contexts(4),/previous month/);
 assert.equal(rows(4).some((f:any)=>f.k==='testsAndLabs'),false,'Counselling and planned tests must not invent performed measurements');
 assert.ok(rows(4).some((f:any)=>f.k==='carePlan' && f.s==='planned' && f.p.t==='At 26 weeks'));
});

 test('uniform schema constrains every context reference to the enclosing original',()=>{
 const input=Array.from({length:20},(_,i)=>({id:String(i).padStart(8,'0')+'-1111-4111-8111-111111111111',text:'Synthetic source '+i+'.'}));
 const result=makePayload(input,template,true,true,true,true,true,true,true,true,true);
 const schema=result.payload.response_format.json_schema.schema;
 for(const [pid,shape] of Object.entries(schema.properties.passages.properties) as any[]){
 const alias=pid.split('.')[0]; const ref=shape.anyOf.find((x:any)=>x.type==='array').items.$ref.split('/').at(-1);
 for(const row of schema.$defs[ref].anyOf){const scope=row.properties.c.items.$ref.split('/').at(-1);assert.deepEqual(schema.$defs[scope].enum,[alias+'.p1']);}
 }
 });
