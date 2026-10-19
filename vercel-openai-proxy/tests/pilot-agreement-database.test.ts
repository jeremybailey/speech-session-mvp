import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Pool } from 'pg';
import { makePilotAgreementHandler } from '../api/v1/agreements/pilot';
import { database } from '../api/_lib/ledger';
import { pilotAgreement, agreementHash } from '../api/_lib/pilot-agreement';

const url = process.env.AGREEMENT_TEST_DATABASE_URL;
test('authenticated audit route with real PostgreSQL concurrency, recovery and immutability', {skip: !url}, async () => {
  const parsed = new URL(url!);
  assert.ok(['127.0.0.1','localhost'].includes(parsed.hostname) && parsed.pathname.startsWith('/cc_test_'), 'Local test database required');
  process.env.DATABASE_URL = url;
  process.env.PILOT_AGREEMENT_VERSION = pilotAgreement.version;
  const admin = new Pool({connectionString:url,max:1});
  const handler = makePilotAgreementHandler(async auth => {
    if (auth === 'Bearer test-a') return 'synthetic-account-a';
    if (auth === 'Bearer test-b') return 'synthetic-account-b';
    throw Object.assign(new Error('unauthorized'), {status:401});
  });
  const request = async (method: string, token?: string, body?: unknown) => {
    let status = 200; let payload: any;
    const res: any = { setHeader() {}, status(code: number) {status=code;return res}, json(data: unknown) {payload=data;return res}, end() {return res} };
    await handler({method, headers:{authorization:token},body} as any,res);
    return {status,payload};
  };
  const body = {version:pilotAgreement.version,sha256:agreementHash,action:pilotAgreement.action,appVersion:'synthetic-test',appBuild:'0',owner:'forged',accepted_at:'yesterday'};
  try {
    await admin.query('DROP TABLE IF EXISTS pilot_agreement_acceptances');
    await admin.query(await readFile('migrations/009_pilot_agreements.sql','utf8'));
    assert.equal((await request('GET')).status,401);
    assert.equal((await request('POST',undefined,body)).status,401);
    assert.equal((await request('GET','Bearer test-a')).payload.receipt,null);
    assert.equal((await request('POST','Bearer test-a',{...body,sha256:'bad'})).status,409);
    assert.equal((await admin.query('SELECT count(*)::int AS n FROM pilot_agreement_acceptances')).rows[0].n,0);
    const results=await Promise.all(Array.from({length:8},()=>request('POST','Bearer test-a',body)));
    for (const result of results) { assert.equal(result.status,200); assert.equal(result.payload.receipt.owner,'synthetic-account-a'); }
    assert.equal(new Set(results.map(r=>r.payload.receipt.id)).size,1);
    assert.equal(new Set(results.map(r=>r.payload.receipt.accepted_at.toISOString())).size,1);
    const recovered=await request('GET','Bearer test-a');
    assert.equal(recovered.payload.receipt.id,results[0].payload.receipt.id);
    assert.equal((await request('GET','Bearer test-b')).payload.receipt,null);
    const second=await request('POST','Bearer test-b',body);
    assert.notEqual(second.payload.receipt.id,recovered.payload.receipt.id);
    const stored=(await admin.query('SELECT * FROM pilot_agreement_acceptances WHERE owner=$1',['synthetic-account-a'])).rows[0];
    assert.equal(stored.app_version,'synthetic-test');
    assert.ok(stored.agreement_text.includes('Content and results may be temporarily retained'));
    assert.ok(stored.accepted_at instanceof Date);
    await assert.rejects(admin.query('UPDATE pilot_agreement_acceptances SET version=$1',['forged']));
    await assert.rejects(admin.query('DELETE FROM pilot_agreement_acceptances'));
    process.env.PILOT_AGREEMENT_VERSION='disabled';
    assert.equal((await request('POST','Bearer test-a',body)).status,503);
    process.env.PILOT_AGREEMENT_VERSION=pilotAgreement.version;
    await admin.query('DROP TABLE pilot_agreement_acceptances');
    assert.equal((await request('POST','Bearer test-a',body)).status,503);
  } finally { await database().end(); await admin.end(); }
});
