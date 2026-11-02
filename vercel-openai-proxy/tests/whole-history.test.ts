import test from 'node:test';
import assert from 'node:assert/strict';
import { makePayload } from '../api/_lib/whole-history-source';
import { makeOverviewPayload } from '../api/_lib/whole-history-overview';
import { validatePayload, requestHash } from '../api/_lib/ledger';
import { summaryModelPolicy } from '../api/_lib/model-policy';
import { outputTokenLimit, reservedOutputTokenLimit } from '../api/_lib/output-policy';
import { reservation } from '../api/_lib/pricing';
import handler from '../api/v1/health-processing/whole-history';
const template = require('../api/_lib/whole-history-template.json');
const records = [{ id: '11111111-1111-4111-8111-111111111111', text: 'Synthetic patient reports intermittent headache.' }];
test('normal B retains source boundaries, rejects changed hashes and malformed input', () => {
 const built = makePayload(records, template);
 assert.equal(built.table['r1.p1'].recordID, records[0].id);
 assert.equal(built.table['r1.p1'].quote, records[0].text);
 assert.equal(validatePayload(built.payload).stage, 'whole-history-generation');
 assert.throws(() => makePayload([{...records[0],sourceSHA256:'wrong'}],template), /source_hash_mismatch/);
 assert.throws(() => makePayload([records[0],records[0]],template), /invalid_records/);
 assert.throws(() => makePayload([],template), /invalid_records/);
 assert.throws(() => makeOverviewPayload(records,{concerns:[],passages:{}},template), /invalid_proposal/);
});
test('B first pass has a reserved 64k allowance; legacy stages keep their limits', () => {
 for (const stage of ['whole-history-generation','whole-history-overview']) {
  assert.deepEqual(summaryModelPolicy(stage), {model:'gpt-6-luna',effort:'medium'});
 }
 assert.equal(outputTokenLimit('gpt-6-luna','whole-history-generation'),64000);
 assert.equal(reservedOutputTokenLimit('gpt-6-luna','whole-history-generation',reservation('gpt-6-luna',64000)),64000);
 assert.equal(outputTokenLimit('gpt-6-luna','whole-history-overview'),6000);
 assert.equal(outputTokenLimit('gpt-6-luna','checking'),6000);
});
test('identical run remains idempotent and different owners remain isolated', () => {
 process.env.AI_DEDUPE_SECRET='synthetic-whole-history-test';
 const p=makePayload(records,template).payload;
 p.input=JSON.stringify({...JSON.parse(p.input),requestIdentity:'run-1'});
 const first=requestHash('owner-a',p,'gpt-6-luna','medium');
 assert.equal(first,requestHash('owner-a',structuredClone(p),'gpt-6-luna','medium'));
 assert.notEqual(first,requestHash('owner-b',p,'gpt-6-luna','medium'));
 p.input=JSON.stringify({...JSON.parse(p.input),requestIdentity:'run-2'});
 assert.notEqual(first,requestHash('owner-a',p,'gpt-6-luna','medium'));
});
test('normal B endpoint rejects anonymous use before ledger or provider access', async () => {
 let status=0; let response:any;
 const res:any={setHeader(){},status(n:number){status=n;return this},json(value:any){response=value;return this},end(){return this}};
 await handler({headers:{},method:'POST',body:{action:'prepare',records}} as any,res);
 assert.equal(status,401);assert.ok(response.error);
});
