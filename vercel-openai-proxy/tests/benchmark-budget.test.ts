import test from 'node:test';
import assert from 'node:assert/strict';
import { checkExperimentAllowance, assertExperimentAllowance, experimentLimit } from '../scripts/benchmark-budget';
import { validDecisionAnswers, validateDecisionRequest } from '../scripts/decisions-benchmark';
const q={type:'choice',name:'claim',instructions:'Use evidence only.',choices:[{value:'Pass',description:'Supported'},{value:'Fail',description:'Not supported'},{value:'Review',description:'Uncertain'}]};
const payload=validateDecisionRequest({model:'gpt-6-luna',input:'Synthetic input',questions:[q]});
const answer={name:'claim',type:'choice',choice:'Pass',confidence:.98,probabilities:[{value:'Pass',probability:.98},{value:'Fail',probability:.01},{value:'Review',probability:.01}]};
test('strict Decisions answers reject missing, duplicate, mismatched, unknown and malformed verdicts',()=>{
 const good={model:'gpt-6-luna',answers:[answer]}; assert.ok(validDecisionAnswers(good,payload));
 for(const a of [{...answer,name:'other'},{...answer,choice:'true'},{...answer,confidence:2},{...answer,probabilities:[]},{...answer,probabilities:[...answer.probabilities.slice(0,2),answer.probabilities[0]]}])
   assert.equal(validDecisionAnswers({...good,answers:[a]},payload),false);
 assert.equal(validDecisionAnswers({...good,answers:[answer,answer]},payload),false);
 assert.equal(validDecisionAnswers({...good,answers:[]},payload),false);
 assert.ok(validDecisionAnswers({...good,answers:[{name:'claim',type:'refusal'}]},payload));
});
test('experiment ceiling counts settled and unresolved reservations across runs',async()=>{
 checkExperimentAllowance(experimentLimit - 214_500_000n,214_500_000n);
 assert.throws(()=>checkExperimentAllowance(experimentLimit - 214_500_000n + 1n,214_500_000n),/experiment_budget/);
 const prefix='benchmark-speed-00000000-0000-0000-0000-000000000001:';
 const db={query:async(sql:string,args:unknown[])=>{assert.match(sql,/COALESCE\(cost_nusd,reserve_nusd\)/);assert.deepEqual(args,[prefix]);return {rows:[{committed:String(experimentLimit - 210_000_000n)}]};}};
 await assert.rejects(assertExperimentAllowance(db as any,prefix,prefix+'candidate',214500000),/experiment_budget/);
 await assert.rejects(assertExperimentAllowance(db as any,prefix,'other',1),/invalid_experiment/);
});
test('serialized admissions cannot oversubscribe the experiment under concurrent callers',async()=>{
 let committed=experimentLimit - 400_000_000n,tail=Promise.resolve();
 // Model the shared row transaction lock; the same admission function executes after acquiring it.
 async function admit(){let release!:()=>void;const previous=tail;tail=new Promise<void>(r=>release=r);await previous;
  try{checkExperimentAllowance(committed,214_500_000n);await Promise.resolve();committed+=214_500_000n;return true;}finally{release();}}
 const attempts=await Promise.allSettled([admit(),admit()]);
 assert.equal(attempts.filter(x=>x.status==='fulfilled').length,1);
 assert.equal(committed,experimentLimit - 185_500_000n);
});
