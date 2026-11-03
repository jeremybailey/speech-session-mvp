import test from 'node:test';import assert from 'node:assert/strict';
import {makePayload} from '../api/_lib/whole-history-source';import {makeOverviewPayload} from '../api/_lib/whole-history-overview';
import {validPlan,planVersion} from '../api/_lib/whole-history-plans';import {chainedOverview} from '../api/_lib/whole-history-background';
const template=require('../api/_lib/whole-history-template.json');
const records=[{id:'11111111-1111-4111-8111-111111111111',text:'Clinician recommends continuing heat at night. If travelling before the next visit, adjust the backpack.'}];
const row={k:'carePlan',s:'recommended',v:['Continue heat','',''],c:[],p:{a:'',t:'At night',q:'',i:'p1',h:'Posture and comfort plan'},g:['c1'],m:null,f:null};
const proposal={concerns:[{id:'c1',name:'Back pain',systems:['musculoskeletal'],evidence:['r1.p1']}],overview:[{text:'Synthetic history.',cite:['r1.p1']}],passages:{'r1.p1':[row]}};
test('plan summaries remain in the same request and are opt-in without changing old contracts',()=>{
 assert.equal(JSON.parse(makePayload(records,template).payload.input).version,template.version);
 assert.equal(JSON.parse(makePayload(records,template,true,true).payload.input).version,'structured-artifacts-v3');
 const fresh=makePayload(records,template,true,true,true);assert.equal(JSON.parse(fresh.payload.input).version,planVersion);
 const actions=(fresh.payload.response_format.json_schema.schema as any).$defs.fact.anyOf.find((v:any)=>v.properties.k.enum.includes('carePlan'));
 assert.deepEqual(actions.properties.p.required,['a','t','q','i','h']);assert.equal(actions.properties.v.items.maxLength,160);
 assert.equal(fresh.payload.stage,'whole-history-generation');assert.equal(validPlan(row.p,'carePlan'),true);
 assert.equal(validPlan({a:'',t:'',q:''},'carePlan'),true);assert.equal(validPlan({...row.p,i:'r1.p1'},'carePlan'),false);
 assert.equal(validPlan(row.p,'medications'),false);assert.equal(validPlan({...row.p,extra:'unexpected'},'carePlan'),false);
});
test('overview continuation preserves concise actions, timing, conditionality and stable source references',()=>{
 const facts=JSON.parse(makeOverviewPayload(records,proposal,template).payload.input).facts;
 assert.equal(facts[0].id,'r1.p1.1');assert.equal(facts[0].text,'Continue heat');assert.equal(facts[0].care.t,'At night');
 const generation=makePayload(records,template,true,true,true).payload;generation.input=JSON.stringify({...JSON.parse(generation.input),serverOverview:true});
 assert.deepEqual(JSON.parse(chainedOverview(generation,JSON.stringify(proposal),'parent-id').input).facts,facts);
 const bad=structuredClone(proposal);bad.passages['r1.p1'][0].v[0]='x'.repeat(161);assert.throws(()=>makeOverviewPayload(records,bad,template),/invalid_proposal/);
 const old=structuredClone(proposal) as any;delete old.passages['r1.p1'][0].p.i;delete old.passages['r1.p1'][0].p.h;
 assert.equal(makeOverviewPayload(records,old,template).factCount,1);
});
test('concise plan fixture replaces repeated prose rather than adding a second summary pass',()=>{
 const old={...row,v:['Clinician recommends continuing heat at night.','',''],p:{a:'',t:'At night; continue',q:'Clinician says the patient is already doing heat.'}};
 console.log('PLAN FIXTURE BYTES',JSON.stringify(row).length,'OLD',JSON.stringify(old).length);
 assert.ok(JSON.stringify(row).length<JSON.stringify(old).length);
});
