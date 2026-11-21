import test from 'node:test';
import assert from 'node:assert/strict';
import { responseDiagnostics } from '../api/_lib/response-diagnostics';

test('incomplete output records limit and reasoning use even without visible output', () => {
  assert.deepEqual(responseDiagnostics({status:'incomplete',incomplete_details:{reason:'max_output_tokens'},usage:{output_tokens_details:{reasoning_tokens:9990}}},10000),
    {providerStatus:'incomplete',incompleteReason:'max_output_tokens',reasoningTokens:9990,outputTokenLimit:10000});
});
test('diagnostics exclude free text, source data and invalid token counts', () => {
  assert.deepEqual(responseDiagnostics({status:'private text',incomplete_details:{reason:'private text'},output_text:'private text',error:{message:'private text'},usage:{output_tokens_details:{reasoning_tokens:-1}}},10000),
    {incompleteReason:'other',outputTokenLimit:10000});
  assert.deepEqual(responseDiagnostics(null,6000),{outputTokenLimit:6000});
  assert.deepEqual(responseDiagnostics({status:'completed',incomplete_details:null},6000),{providerStatus:'completed',outputTokenLimit:6000});
});

test('background timings distinguish provider lifecycle from delayed collection',()=>{
 assert.deepEqual(responseDiagnostics({status:'completed',created_at:1000,completed_at:1025},6000,1027.125),{outputTokenLimit:6000,providerStatus:'completed',providerLifecycleSeconds:25,collectionDelaySeconds:2.125});
 for(const response of [{status:'in_progress',created_at:1000,completed_at:1025},{status:'completed',created_at:1025,completed_at:1000},{status:'completed',created_at:'source text',completed_at:1025},{status:'completed',created_at:1000,completed_at:Infinity}]) {
  const d=responseDiagnostics(response,6000,1030);assert.equal(d.providerLifecycleSeconds,undefined);assert.equal(d.collectionDelaySeconds,undefined);
 }
 assert.equal(responseDiagnostics({status:'completed',created_at:1000,completed_at:1025},6000,1020).collectionDelaySeconds,undefined);
});
