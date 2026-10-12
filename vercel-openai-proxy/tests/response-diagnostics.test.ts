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
