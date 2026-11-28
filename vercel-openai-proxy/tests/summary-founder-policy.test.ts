import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {validateSummaryInput,summaryPayload,summaryPlan,validatePoints,summaryResult,auditSourceCoverageFailure,SummaryInput} from '../api/_lib/summary-workflow';
const input=():SummaryInput=>({id:randomUUID(),contract:'summary-workflow-v1',kind:'practitioner',template:'practitioner',target:'test',sourceRevision:'a',publicationRevision:'b',practitionerPolicy:'founder-v1',preparedDate:'2026-11-24',evidence:[{id:'e1',text:'About 10 years before September 2024, pelvic weakness. Physiotherapy helped partially.'}]});
const base={heading:'Comprehensive Health History',text:'Pelvic weakness — about 10 years before September 2024',citationIDs:['e1'],topic:null,recipient:null,stance:null,subjectCitation:null,responseCitation:null,visitSection:null,conditionGroup:'Pelvic symptoms',careStatus:null,timeLabel:'10 years before September 2024'};
test('founder trial opt-in is validated and legacy inputs stay unchanged',()=>{
 const p=input();assert.equal(validateSummaryInput(p).practitionerPolicy,'founder-v1');
 assert.throws(()=>validateSummaryInput({...p,kind:'record',template:'visit'}));
 assert.throws(()=>validateSummaryInput({...p,preparedDate:'yesterday'}));
 const {practitionerPolicy,preparedDate,...old}=p;assert.equal(validateSummaryInput(old).practitionerPolicy,undefined);
 const payload=summaryPayload(old,summaryPlan(old)[0],{},0);assert.ok(!payload.instructions.includes('FOUNDER V1 RULES'));
});
test('all generation phases carry founder rules and prepared date',()=>{
 const p=input();for(const s of summaryPlan(p)){
  const payload=summaryPayload(p,s,{},0);assert.match(payload.instructions,/Never convert relative times/);assert.match(payload.instructions,/actually consulted/);assert.match(payload.instructions,/No new clinical interpretation/);assert.equal(JSON.parse(payload.input as string).preparedDate,p.preparedDate);
 }
});
test('calculated years are suppressed; original statement and citations survive',()=>{
 const p=input(),s=summaryPlan(p)[0];
 const temporal={role:'event',start:'2014',end:null,approximate:true,sourceQuote:'About 10 years before September 2024',citationIDs:['e1']};
 const [result]=validatePoints(JSON.stringify({points:[{...base,temporal}]}),p,s,{});
 assert.equal(result.temporal?.role,'unknown');assert.equal(result.text,base.text);assert.deepEqual(result.citationIDs,['e1']);assert.equal(result.timeLabel,base.timeLabel);
});
test('invented period and invalid treatment status cannot become display metadata',()=>{
 const p=input(),s=summaryPlan(p)[0];
 const [result]=validatePoints(JSON.stringify({points:[{...base,timeLabel:'Childhood'}]}),p,s,{});assert.equal(result.timeLabel,null);
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...base,careStatus:'Cured'}]}),p,s,{}));
});
test('result preserves grouping and provenance with version marker',()=>{
 const p=input(),plan=summaryPlan(p);const result=summaryResult(p,plan,{'audit:0':[base]});
 assert.equal(result.practitionerPolicy,'founder-v1');assert.equal(result.points[0].conditionGroup,'Pelvic symptoms');assert.deepEqual(result.citationIDs,['e1']);
});

test('a dated observation survives unrelated relative history in the same quote',()=>{
 const p=input();p.evidence=[{id:'e1',text:'Visit September 6, 2024: pelvic weakness about 10 years before September 2024. Breastfeeding at this visit.'}];
 const point={...base,text:'Breastfeeding — at September 6, 2024 visit',timeLabel:null,temporal:{role:'ongoing',start:'2024-09-06',end:null,approximate:false,sourceQuote:p.evidence[0].text,citationIDs:['e1']}};
 const [result]=validatePoints(JSON.stringify({points:[point]}),p,summaryPlan(p)[0],{});
 assert.equal(result.temporal?.start,'2024-09-06');
});

test('an audit cannot silently discard a checked clinical source passage',()=>{
 const p=input();p.evidence.push({id:'e2',text:'Iron discussed, not started.'});
 const step=summaryPlan(p).find(s=>s.phase==='audit')!;
 const outputs={ [step.dependencies[0]]:[{...base,heading:'Care Plan & Interventions',text:'Iron — discussed, not started',citationIDs:['e2'],careStatus:'Discussed, not started'}] };
 assert.throws(()=>validatePoints(JSON.stringify({points:[{...base,historyIDs:[],coordinationIDs:[]}]}),p,step,outputs));
});

test('empty uncited section placeholders do not cause another model call',()=>{
 const p=input(),s=summaryPlan(p)[0];
 const blank={...base,heading:'Appointment Preparation Brief',text:'',citationIDs:[],conditionGroup:null};
 const result=validatePoints(JSON.stringify({points:[base,blank]}),p,s,{});
 assert.equal(result.length,1);assert.equal(result[0].text,base.text);
});

// Synthetic duplicate-source case: shortening a point must not lose provenance.
test('source-only audit failure gets the existing bounded retry; invalid content does not',()=>{
 const p=input();p.evidence.push({id:'e2',text:p.evidence[0].text});
 const step=summaryPlan(p).find(s=>s.phase==='audit')!;
 const original={...base,heading:'Clinical Snapshot',citationIDs:['e1','e2']};
 const outputs={[step.dependencies[0]]:[original]};
 const candidate={...original,text:'Pelvic weakness — historical',citationIDs:['e1'],historyIDs:[],coordinationIDs:[]};
 const raw=JSON.stringify({points:[candidate]});
 assert.throws(()=>validatePoints(raw,p,step,outputs),/invalid_summary_output/);
 assert.equal(auditSourceCoverageFailure(raw,p,step,outputs),true);
 for(const change of [{citationIDs:['invented']},{careStatus:'Cured'},{historyIDs:['history:999']},{text:''}]){
  assert.equal(auditSourceCoverageFailure(JSON.stringify({points:[{...candidate,...change}]}),p,step,outputs),false);
 }
 const repaired=JSON.stringify({points:[{...candidate,citationIDs:['e1','e2']}]});
 assert.equal(validatePoints(repaired,p,step,outputs).length,1);
 assert.equal(auditSourceCoverageFailure(repaired,p,step,outputs),false);
 const payload=summaryPayload(p,step,outputs,2);
 assert.deepEqual(JSON.parse(payload.input as string).requiredSourceIDs,['e1','e2']);
 assert.match(payload.instructions,/preserve all supporting original source IDs/);
 const legacy={...p,practitionerPolicy:undefined};
 assert.equal(auditSourceCoverageFailure(raw,legacy,step,outputs),false);
 assert.equal(JSON.parse(summaryPayload(legacy,step,outputs,2).input as string).requiredSourceIDs,undefined);
});
