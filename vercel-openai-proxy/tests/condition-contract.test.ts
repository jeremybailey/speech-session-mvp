import test from 'node:test';
import assert from 'node:assert/strict';
import {ConditionPlan,initialConditionState,acceptConditionResponse,nextConditionRequest,repairVerificationContract,recoverSavedMapping} from '../api/_lib/condition-workflow';

const id=(n:number)=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const contract={instructions:'Synthetic source-only contract',response_format:{type:'json_schema',json_schema:{name:'test',strict:true,schema:{type:'object',properties:{},additionalProperties:false}}}};
function fixture(compact=false):ConditionPlan {
  return {version:1,...(compact?{evidenceEncoding:'table-v1' as const}:{}),preserved:{groups:[],unassigned:[]},contextEntries:[],
    batches:[[{id:id(1),title:'Reported knee pain',excerpt:'My knee hurts.'},{id:id(2),title:'Sleep difficulty',excerpt:'I cannot fall asleep.'}]],mapping:contract,verification:contract};
}
const groups=[{name:'Knee pain',bodySystem:'musculoskeletal',isPrimary:false,reason:'Reported symptom',entryIDs:['r1']},
  {name:'Sleep difficulty',bodySystem:'unknown',isPrimary:false,reason:'Reported symptom',entryIDs:['r2']}];
const mapping=()=>({groups:structuredClone(groups),unassigned:[]});
const verdict=()=>({decisions:groups.map(g=>({name:g.name,bodySystem:g.bodySystem,nameSupported:true,supportedEntryIDs:[...g.entryIDs],reason:'Source supports the association.'}))});
const compactVerdict=()=>({decisions:{g0:{ok:true,entries:['r1'],reason:null},g1:{ok:true,entries:['r2'],reason:null}}});
type Mutation={name:string;repair?:boolean;mutate:(v:any)=>void};
const mutations:Mutation[]=[
 {name:'invented ID',repair:true,mutate:v=>v.decisions[1].supportedEntryIDs.push('r99')},
 {name:'wrong-group ID',repair:true,mutate:v=>v.decisions[0].supportedEntryIDs=['r2']},
 {name:'renamed heading',repair:true,mutate:v=>v.decisions[0].name+=' with unsupported qualifier'},
 {name:'changed body system',repair:true,mutate:v=>v.decisions[0].bodySystem='eye'},
 {name:'missing group',mutate:v=>v.decisions.pop()},
 {name:'extra group',mutate:v=>v.decisions.push(structuredClone(v.decisions[0]))},
 {name:'duplicate group',mutate:v=>v.decisions[1]=structuredClone(v.decisions[0])},
 {name:'duplicate occurrence ID',mutate:v=>v.decisions[0].supportedEntryIDs.push('r1')},
 {name:'numeric ID',mutate:v=>v.decisions[0].supportedEntryIDs=[1]},
 {name:'missing IDs',mutate:v=>delete v.decisions[0].supportedEntryIDs},
 {name:'string verdict',mutate:v=>v.decisions[0].nameSupported='true'},
 {name:'missing verdict',mutate:v=>delete v.decisions[0].nameSupported},
 {name:'empty reason',mutate:v=>v.decisions[0].reason=' '},
 {name:'missing reason',mutate:v=>delete v.decisions[0].reason},
 {name:'null decision',mutate:v=>v.decisions[0]=null},
 {name:'null envelope',mutate:v=>v.decisions=null},
];
for(const fault of mutations) test(`legacy verifier mutation: ${fault.name}`,()=>{
 const p=fixture(),s=acceptConditionResponse(p,initialConditionState(p),JSON.stringify(mapping())),before=structuredClone(s);
 const value=verdict();fault.mutate(value);const raw=JSON.stringify(value);
 assert.throws(()=>acceptConditionResponse(p,s,raw));assert.deepEqual(s,before,'Failure cannot partially publish earlier valid decisions');
 const repair=repairVerificationContract(p,s,raw);
 assert.equal(!!repair,!!fault.repair);
 if(repair) {
  assert.deepEqual(repair.result,s.result);assert.deepEqual(repair.proposal,s.proposal);
  assert.equal(repairVerificationContract(p,repair,raw),null,'Bounded repair cannot loop');
  const req=nextConditionRequest(p,repair)!;
  assert.notDeepEqual(req.payload,nextConditionRequest(p,s)!.payload);
  const done=acceptConditionResponse(p,JSON.parse(JSON.stringify(repair)),JSON.stringify(compactVerdict()));
  assert.equal(done.phase,'completed');assert.deepEqual(done.result.groups.flatMap(g=>g.entryIDs),[id(1),id(2)]);
 }
});
for(const raw of ['{"decisions":','I cannot comply','null','[]',JSON.stringify({refusal:'Refused'}),'x'.repeat(200001)])
 test(`invalid envelope ${raw.slice(0,24)}`,()=>{
  const p=fixture(),s=acceptConditionResponse(p,initialConditionState(p),JSON.stringify(mapping())),before=structuredClone(s);
  assert.throws(()=>acceptConditionResponse(p,s,raw));assert.equal(repairVerificationContract(p,s,raw),null);assert.deepEqual(s,before);
 });
const compactMutations:Mutation[]=[
 {name:'unknown group key',mutate:v=>{v.decisions.g9=v.decisions.g1;delete v.decisions.g1;}},
 {name:'extra group key',mutate:v=>v.decisions.g9=v.decisions.g1},
 {name:'missing group key',mutate:v=>delete v.decisions.g1},
 {name:'unknown entry',mutate:v=>v.decisions.g1.entries=['r99']},
 {name:'wrong group entry',mutate:v=>v.decisions.g1.entries=['r1']},
 {name:'duplicate entry',mutate:v=>v.decisions.g1.entries=['r2','r2']},
 {name:'extra field',mutate:v=>v.decisions.g1.name='Renamed'},
 {name:'refusal shape',mutate:v=>v.decisions.g1={refusal:'Refused'}},
 {name:'false without reason',mutate:v=>v.decisions.g1.ok=false},
 {name:'omission without reason',mutate:v=>v.decisions.g1.entries=[]},
 {name:'string verdict',mutate:v=>v.decisions.g1.ok='true'},
];
for(const fault of compactMutations) test(`compact verifier mutation: ${fault.name}`,()=>{
 const p=fixture(true),s=acceptConditionResponse(p,initialConditionState(p),JSON.stringify(mapping())),before=structuredClone(s),v=compactVerdict();
 fault.mutate(v);assert.throws(()=>acceptConditionResponse(p,s,JSON.stringify(v)));
 assert.deepEqual(s,before);assert.equal(repairVerificationContract(p,s,JSON.stringify(v)),null);
});
for(const reason of ['Wrong person: this is family history.','The symptom was denied.','Conditional plan only; no documented indication.','Medication dose does not establish its indication.'])
 test(`negative judgment is preserved: ${reason}`,()=>{
  const p=fixture(),s=acceptConditionResponse(p,initialConditionState(p),JSON.stringify(mapping())),v=verdict();
  Object.assign(v.decisions[1],{nameSupported:false,supportedEntryIDs:[],reason});
  assert.equal(repairVerificationContract(p,s,JSON.stringify(v)),null);
  const done=acceptConditionResponse(p,s,JSON.stringify(v));assert.deepEqual(done.result.unassigned,[id(2)]);
  assert.deepEqual(done.result.groups.flatMap(g=>g.entryIDs),[id(1)]);
 });
test('decision ordering does not change source identity or final result',()=>{
 const p=fixture(),s=acceptConditionResponse(p,initialConditionState(p),JSON.stringify(mapping())),v=verdict();
 const expected=acceptConditionResponse(p,s,JSON.stringify(v));v.decisions.reverse();
 assert.deepEqual(acceptConditionResponse(p,s,JSON.stringify(v)),expected);
});

for(const fault of [
 {name:'invented mapping ID',mutate:(v:any)=>v.groups[0].entryIDs=['r99']},
 {name:'overlapping groups',mutate:(v:any)=>v.groups[1].entryIDs=['r1']},
 {name:'duplicate member',mutate:(v:any)=>v.groups[0].entryIDs=['r1','r1']},
 {name:'assigned and unassigned',mutate:(v:any)=>v.unassigned=['r1']},
 {name:'multiple primary groups',mutate:(v:any)=>v.groups.forEach((g:any)=>g.isPrimary=true)},
 {name:'unknown body system',mutate:(v:any)=>v.groups[0].bodySystem='invented'},
 {name:'empty heading',mutate:(v:any)=>v.groups[0].name=''},
 {name:'oversized heading',mutate:(v:any)=>v.groups[0].name='x'.repeat(81)},
 {name:'missing rationale',mutate:(v:any)=>delete v.groups[0].reason},
]) test(`mapping mutation: ${fault.name}`,()=>{
 const p=fixture(),s=initialConditionState(p),before=structuredClone(s),v=mapping();fault.mutate(v);
 assert.throws(()=>acceptConditionResponse(p,s,JSON.stringify(v)));assert.deepEqual(s,before);
});
test('mapping omission repairs once without silently dropping an occurrence',()=>{
 const p=fixture(),s=initialConditionState(p),v=mapping();v.groups.pop();
 const retry=acceptConditionResponse(p,s,JSON.stringify(v));assert.equal(retry.coverageRetry,true);
 assert.deepEqual(retry.result,s.result);assert.throws(()=>acceptConditionResponse(p,retry,JSON.stringify(v)));
 const checking=acceptConditionResponse(p,retry,JSON.stringify(mapping()));
 const done=acceptConditionResponse(p,checking,JSON.stringify(verdict()));
 assert.equal(done.phase,'completed');assert.deepEqual(done.result.groups.flatMap(g=>g.entryIDs),[id(1),id(2)]);
});

for(const compact of [false,true]) test(`generic report headings reach independent review, compact=${compact}`,()=>{
 const p=fixture(compact), before=initialConditionState(p), value=mapping();
 value.groups[0].name='Screening test findings';
 const checking=recoverSavedMapping(p,before,JSON.stringify(value))!;
 assert.equal(checking.phase,'verification');
 assert.deepEqual(checking.result,before.result,'Unverified mappings cannot publish');
 assert.match(nextConditionRequest(p,checking)!.payload.instructions,/Judge meaning in context/);
 const answer=compact?{decisions:{g0:{ok:false,entries:[],reason:'Report heading only.'},g1:{ok:true,entries:['r2'],reason:null}}}
  :{decisions:[{name:'Screening test findings',bodySystem:'musculoskeletal',nameSupported:false,supportedEntryIDs:[],reason:'Report heading only.'},verdict().decisions[1]]};
 const done=acceptConditionResponse(p,checking,JSON.stringify(answer));
 assert.equal(done.phase,'completed');
 assert.deepEqual(done.result.unassigned,[id(1)]);
 assert.deepEqual(done.result.groups.flatMap(g=>g.entryIDs),[id(2)]);
 assert.deepEqual(before,initialConditionState(p));
 assert.equal(recoverSavedMapping(p,checking,JSON.stringify(value)),null);
});
test('saved mapping recovery never bypasses occurrence validation or invents paid repairs',()=>{
 const p=fixture(),s=initialConditionState(p);
 for(const raw of ['null','{',JSON.stringify({groups:[],unassigned:[]}),JSON.stringify({groups:[],unassigned:['r99']}),JSON.stringify({groups:[],unassigned:['r1','r1']})])
  assert.equal(recoverSavedMapping(p,s,raw),null);
});
