import test from 'node:test';
import assert from 'node:assert/strict';
import {makePayload} from '../api/_lib/whole-history-source';
import {makeOverviewPayload} from '../api/_lib/whole-history-overview';
import {artifactFields,artifactVersion,validArtifact,groundedArtifact} from '../api/_lib/whole-history-artifacts';
import {chainedOverview} from '../api/_lib/whole-history-background';
const template=require('../api/_lib/whole-history-template.json');
const records=[{id:'11111111-1111-4111-8111-111111111111',text:'Dr. Jane Doe, Example Clinic. Suite 2, 123 Example St, Toronto ON M1M 1M1; phone 416-555-0123. No confirmed diagnosis.'}];
const fields=[['name','Dr. Jane Doe'],['organization','Example Clinic'],['address','Suite 2, 123 Example St, Toronto ON M1M 1M1'],['phone','416-555-0123']];
const proposal:any={concerns:[{id:'c1',name:'Synthetic concern',systems:['unknown'],evidence:['r1.p1']}],overview:[{text:'Synthetic history.',cite:['r1.p1']}],passages:{'r1.p1':[{k:'practitionerContact',s:'reported',v:['Dr. Jane Doe','',''],c:[],p:null,g:['c1'],m:null,f:fields}]}};
test('sparse typed categories are opt-in; legacy/v2 payloads retain their protocols',()=>{
 assert.equal(JSON.parse(makePayload(records,template).payload.input).version,template.version);
 assert.equal(JSON.parse(makePayload(records,template,true).payload.input).version,'structured-medications-v2');
 const next=makePayload(records,template,true,true);
 assert.equal(JSON.parse(next.payload.input).version,artifactVersion);
 assert.ok((next.payload.response_format.json_schema.schema as any).$defs.fact.anyOf.every((v:any)=>v.required.includes('f')));
 assert.equal(template.version,'compact-actions-short-overview-v1');
 for(const [category,keys] of Object.entries(artifactFields)){
  assert.equal(validArtifact(keys.map(k=>[k,'source value']),category),true);
  assert.equal(validArtifact([['unsupported','value']],category),false);
 }
 assert.equal(validArtifact(null,'medications'),true);assert.equal(validArtifact(null,'carePlan'),true);
 assert.equal(validArtifact(null,'practitionerContact'),false);
 assert.equal(validArtifact([['name','Dr. Jane Doe'],['name','Dr. John Doe']],'practitionerContact'),false);
});
test('overview and durable continuation retain grounded fields and original fact identities',()=>{
 const built=makeOverviewPayload(records,proposal,template),input=JSON.parse(built.payload.input);
 assert.deepEqual(input.facts[0].fields,fields);assert.equal(input.facts[0].id,'r1.p1.1');
 const generation=makePayload(records,template,true,true).payload;generation.input=JSON.stringify({...JSON.parse(generation.input),serverOverview:true});
 assert.deepEqual(JSON.parse(chainedOverview(generation,JSON.stringify(proposal),'parent-id').input).facts[0].fields,fields);
 const invalid=structuredClone(proposal);invalid.passages['r1.p1'][0].f=[['phone','invented']];
 assert.deepEqual(JSON.parse(makeOverviewPayload(records,invalid,template).payload.input).facts[0].fields,[]);
 assert.deepEqual(groundedArtifact([['address','Another address']], [records[0].text]),[]);
 invalid.passages['r1.p1'][0].f=[['invented','value']];assert.throws(()=>makeOverviewPayload(records,invalid,template),/invalid_proposal/);
});
test('structured fixture replaces prose inventory without a new processing stage',()=>{
 const legacy={...proposal.passages['r1.p1'][0],v:['Invoice identifies Dr. Jane Doe of Example Clinic, at Suite 2, 123 Example St, Toronto ON M1M 1M1; phone 416-555-0123.','','']};delete (legacy as any).f;
 // Byte counts are an offline size proxy, never a timing or model-quality claim.
 console.log('STRUCTURED FIXTURE BYTES',JSON.stringify(proposal.passages['r1.p1'][0]).length,'LEGACY',JSON.stringify(legacy).length);
 assert.equal(makePayload(records,template,true,true).payload.stage,'whole-history-generation');
});
