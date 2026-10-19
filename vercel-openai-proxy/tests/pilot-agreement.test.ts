import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { pilotAgreement, agreementText, agreementHash, validateAcceptance } from '../api/_lib/pilot-agreement';
const body = { version: pilotAgreement.version, sha256: agreementHash, action: pilotAgreement.action, appVersion: '1.0993', appBuild: '17' };
test('hash identifies the exact displayed text and affirmative action', () => {
  assert.equal(agreementHash, createHash('sha256').update(agreementText).digest('hex'));
  assert.equal(pilotAgreement.paragraphs.length, 7);
  assert.notEqual(agreementHash, createHash('sha256').update(agreementText + ' ').digest('hex'));
});
test('acceptance rejects old text, stale versions, implicit action and invalid metadata', () => {
  for (const bad of [null, {}, {...body,version:'old'}, {...body,sha256:'0'.repeat(64)}, {...body,action:'dismiss'}, {...body,appBuild:''}, {...body,appVersion:'x'.repeat(41)}]) {
    assert.throws(() => validateAcceptance(bad));
  }
  assert.deepEqual(validateAcceptance({...body,owner:'forged',accepted_at:'yesterday'}), { appVersion:'1.0993',appBuild:'17' });
});
