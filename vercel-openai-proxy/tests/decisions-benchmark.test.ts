import test from 'node:test';
import assert from 'node:assert/strict';
import { decisionCost, decisionsReservation, validateDecisionRequest } from '../scripts/decisions-benchmark';

test('Decisions input-only pricing is bounded; unknown usage holds the reservation', () => {
  assert.equal(decisionCost({input_tokens:1000,output_tokens:0,input_tokens_details:{cached_tokens:900}}),100000);
  assert.equal(decisionCost({input_tokens:272001,output_tokens:0}),54400200);
  assert.equal(decisionCost({input_tokens:1050000,output_tokens:0}),decisionsReservation);
  for (const usage of [undefined,{}, {input_tokens:1}, {input_tokens:-1,output_tokens:0},
    {input_tokens:1.5,output_tokens:0},{input_tokens:1050001,output_tokens:0},
    {input_tokens:100,output_tokens:1}]) assert.equal(decisionCost(usage),null);
});
test('Decisions diagnostic rejects unbounded or ambiguous questions and model overrides', () => {
  const q = {type:'choice',name:'criterion',instructions:'Use the supplied evidence.',
    choices:[{value:'Pass',description:'All requirements met.'},{value:'Fail',description:'A requirement is contradicted or absent.'},{value:'Review',description:'Evidence cannot resolve it.'}]};
  const p = {model:'gpt-6-luna',input:'Synthetic evidence',questions:[q]};
  assert.deepEqual(validateDecisionRequest({...p,store:true}),p);
  for (const invalid of [{...p,model:'other'},{...p,input:'x'.repeat(50001)},
    {...p,questions:[]},{...p,questions:[q,q]},
    {...p,questions:[{...q,choices:q.choices.slice(0,2)}]},
    {...p,questions:[{...q,type:'score'}]}]) assert.throws(()=>validateDecisionRequest(invalid));
});
