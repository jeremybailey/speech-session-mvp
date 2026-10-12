import test from 'node:test';
import assert from 'node:assert/strict';
import { processingOwner, speedExperimentPrefix, fastDetailsCapacity, enforceFastDetailsBudget } from '../api/_lib/fast-details-experiment';
import { validatePayload } from '../api/_lib/ledger';
import type { PoolClient } from 'pg';
test('experimental owners and payloads are isolated and require explicit enablement', () => {
  const old = process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
  try {
    delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
    assert.equal(processingOwner('person'), 'person');
    const payload = {stage:'extraction',instructions:'Pipeline: fast-details-v1',input:'synthetic',response_format:{type:'json_object'}};
    assert.throws(() => validatePayload(payload), /fast_experiment_disabled/);
    process.env.FAST_DETAILS_EXPERIMENT_ENABLED = 'true';
    assert.ok(processingOwner('person').startsWith(speedExperimentPrefix+'fast-details-app:'));
    assert.equal(processingOwner('person'),processingOwner('person'));
    assert.notEqual(processingOwner('person'),processingOwner('other'));
    assert.equal(validatePayload(payload).stage,'extraction');
  } finally { if(old === undefined) delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED; else process.env.FAST_DETAILS_EXPERIMENT_ENABLED=old; }
});
test('capacity accounts for full reservations, never exceeds four', () => {
  assert.equal(fastDetailsCapacity(348984400n,217500000n),1);
  assert.equal(fastDetailsCapacity(870000000n,217500000n),4);
  assert.equal(fastDetailsCapacity(10000000000n,217500000n),4);
  assert.equal(fastDetailsCapacity(214000000n,217500000n),0);
});
test('historical unknown charges remain in cumulative experiment allowance', async () => {
  const old=process.env.FAST_DETAILS_EXPERIMENT_ENABLED;process.env.FAST_DETAILS_EXPERIMENT_ENABLED='true';
  try {
    const db={query:async(sql:string,args:unknown[])=>{assert.ok(sql.includes('COALESCE(cost_nusd,reserve_nusd)'));assert.equal(args[0],speedExperimentPrefix);return {rows:[{committed:'2140000000'}]};}} as unknown as PoolClient;
    await assert.rejects(enforceFastDetailsBudget(db,processingOwner('person'),217500000),/budget_exhausted/);
  } finally {if(old===undefined) delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED; else process.env.FAST_DETAILS_EXPERIMENT_ENABLED=old;}
});

test('ordinary owners never query experiment accounting and disabled experiment owners fail closed', async () => {
  const old = process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
  delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
  try {
    const db = {query: async () => { throw Error('Unexpected experiment accounting query'); }} as unknown as PoolClient;
    await enforceFastDetailsBudget(db, 'ordinary-user', 217500000);
    await assert.rejects(enforceFastDetailsBudget(db, speedExperimentPrefix + 'fast-details-app:synthetic', 217500000), /fast_experiment_disabled/);
  } finally { if (old === undefined) delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED; else process.env.FAST_DETAILS_EXPERIMENT_ENABLED = old; }
});
