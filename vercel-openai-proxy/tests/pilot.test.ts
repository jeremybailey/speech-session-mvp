import test from 'node:test';
import assert from 'node:assert/strict';
import {durableEnabledForOwner} from '../api/_lib/pilot';
test('authenticated alpha accounts share budgeted processing without a second allowlist',()=>{
  process.env.VERCEL_ENV='production';process.env.AI_DURABLE_ENABLED='true';
  delete process.env.AI_PILOT_SUBJECT_HASHES;
  assert.equal(durableEnabledForOwner('selected'),true);
  process.env.AI_PILOT_SUBJECT_HASHES='*';
  assert.equal(durableEnabledForOwner('selected'),true);
  assert.equal(durableEnabledForOwner('other'),true);
  assert.equal(durableEnabledForOwner(''),false);
  assert.equal(durableEnabledForOwner('   '),false);
  process.env.AI_DURABLE_ENABLED='false';
  assert.equal(durableEnabledForOwner('selected'),false);
});
