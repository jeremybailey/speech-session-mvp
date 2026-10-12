import test from 'node:test';
import assert from 'node:assert/strict';
import { processingOwner, isFastRequest, speedExperimentPrefix, fastDetailsCapacity, enforceFastDetailsBudget } from '../api/_lib/fast-details-experiment';
import { validatePayload } from '../api/_lib/ledger';
import { experimentLimit } from '../scripts/benchmark-budget';
import type { PoolClient } from 'pg';
test('experimental owners and payloads are isolated and require explicit enablement', () => {
  const old = process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
  try {
    delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
    assert.equal(processingOwner('person'), 'person');
    const payload = {stage:'extraction',instructions:'Pipeline: fast-details-v1',input:'synthetic',response_format:{type:'json_object'}};
    assert.throws(() => validatePayload(payload), /fast_experiment_disabled/);
    process.env.FAST_DETAILS_EXPERIMENT_ENABLED = 'true';
    assert.ok(processingOwner('person', true).startsWith(speedExperimentPrefix+'fast-details-app:'));
    assert.equal(processingOwner('person', true),processingOwner('person', true));
    assert.notEqual(processingOwner('person', true),processingOwner('other', true));
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
    const db={query:async(sql:string,args:unknown[])=>{assert.ok(sql.includes('COALESCE(cost_nusd,reserve_nusd)'));assert.equal(args[0],speedExperimentPrefix);return {rows:[{committed:String(experimentLimit - 110_000_000n)}]};}} as unknown as PoolClient;
    await assert.rejects(enforceFastDetailsBudget(db,processingOwner('person', true),217500000),/budget_exhausted/);
  } finally {if(old===undefined) delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED; else process.env.FAST_DETAILS_EXPERIMENT_ENABLED=old;}
});

test('ordinary owners skip experiment accounting; experimental owners always use it', async () => {
  const old = process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
  delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
  try {
    const db = {query: async () => { throw Error('Unexpected experiment accounting query'); }} as unknown as PoolClient;
    await enforceFastDetailsBudget(db, 'ordinary-user', 217500000);
    await assert.rejects(enforceFastDetailsBudget(db, speedExperimentPrefix + 'fast-details-app:synthetic', 217500000), /Unexpected experiment accounting query/);
  } finally { if (old === undefined) delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED; else process.env.FAST_DETAILS_EXPERIMENT_ENABLED = old; }
});

test('shared backend keeps ordinary users unchanged and scopes only explicit fast requests',()=>{
 assert.equal(isFastRequest({}),false);
 assert.equal(isFastRequest({'x-collectivecare-pipeline':['fast-details']}),false);
 assert.equal(isFastRequest({'x-collectivecare-pipeline':'fast-details'}),true);
 assert.equal(processingOwner('asha'), 'asha');
 assert.notEqual(processingOwner('jeremy',true), processingOwner('asha',true));
 const p={stage:'checking',instructions:'Pipeline: fast-details-v2.1',input:'synthetic',response_format:{type:'json_object'}};
 assert.equal(validatePayload(p,true).stage,'checking');
 assert.throws(()=>validatePayload(p,false),/fast_experiment_disabled/);
});

test('release capacity uses the shared allowance while experiments retain their sub-limit',async()=>{
 const {readFastDetailsCapacity}=await import('../api/_lib/fast-details-experiment');
 const queries:string[]=[];
 const db={query:async(sql:string)=>{queries.push(sql);return {rows:[sql.includes('ai_budgets')?{limit_nusd:'5000000000',used_nusd:'4000000000',reserved_nusd:'100000000'}:{committed:String(experimentLimit-100000000n)}]};}} as unknown as PoolClient;
 assert.equal((await readFastDetailsCapacity(db,'shared',200000000,false)).maxInFlight,4);
 assert.equal(queries.length,1);
 assert.equal((await readFastDetailsCapacity(db,'shared',200000000,true)).maxInFlight,0);
 assert.equal(queries.length,3);
});

test('the released checked-facts contract works without an experimental flag; unknown versions stay gated',()=>{
 const old=process.env.FAST_DETAILS_EXPERIMENT_ENABLED;delete process.env.FAST_DETAILS_EXPERIMENT_ENABLED;
 const p={stage:'checking',instructions:'Pipeline: fast-details-v2.2\nSynthetic independent check',input:'synthetic',response_format:{type:'json_object'}};
 try {assert.equal(validatePayload(p).stage,'checking');assert.throws(()=>validatePayload({...p,instructions:'Pipeline: fast-details-v2.20\nSynthetic'}),/fast_experiment_disabled/);}
 finally {if(old!==undefined)process.env.FAST_DETAILS_EXPERIMENT_ENABLED=old;}
});
