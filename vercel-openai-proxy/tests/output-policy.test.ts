import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { outputTokenLimit, reservedOutputTokenLimit } from '../api/_lib/output-policy';
import { reservation } from '../api/_lib/pricing';
import { requestHash } from '../api/_lib/ledger';
import { modelIdentity } from '../api/_lib/model-policy';

test('larger extraction output is reserved; old queued jobs retain their original bound', () => {
  const model = 'gpt-6-luna';
  assert.equal(outputTokenLimit(model, 'extraction'), 10000);
  assert.equal(reservedOutputTokenLimit(model, 'extraction', reservation(model, 10000)), 10000);
  assert.equal(reservedOutputTokenLimit(model, 'extraction', String(reservation(model, 6000))), 6000);
  assert.throws(() => reservedOutputTokenLimit(model, 'extraction', 0));
  for (const stage of ['checking', 'classification', 'condition-synthesis', 'condition-verification']) {
    assert.equal(outputTokenLimit(model, stage), 6000);
    assert.equal(reservedOutputTokenLimit(model, stage, reservation(model, 10000)), 6000);
  }
  assert.equal(outputTokenLimit('gpt-4o-mini', 'extraction'), 6000);
});

test('new extraction cannot reuse an old truncated job; other request identities remain stable', () => {
  process.env.AI_DEDUPE_SECRET = 'synthetic-output-policy';
  function canonical(value: any): string {
    if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
    if (value && typeof value === 'object') return `{${Object.entries(value).sort(([a],[b]) => a.localeCompare(b)).map(([k,v])=>`${JSON.stringify(k)}:${canonical(v)}`).join(',')}}`;
    return JSON.stringify(value);
  }
  for (const stage of ['extraction', 'checking', 'classification', 'condition-verification']) {
    const payload = {stage, instructions:'Synthetic', input:'Synthetic', response_format:{type:'json_object'}};
    const legacy = createHmac('sha256', process.env.AI_DEDUPE_SECRET).update(canonical(['owner','durable-v1',modelIdentity('gpt-6-luna','medium'),payload])).digest('hex');
    const current = requestHash('owner',payload,'gpt-6-luna','medium');
    if (stage === 'extraction') assert.notEqual(current,legacy);
    else assert.equal(current,legacy);
  }
});
