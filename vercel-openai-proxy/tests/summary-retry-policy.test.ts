import test from 'node:test';
import assert from 'node:assert/strict';
import {mayReplaceUnconfirmedStep} from '../api/_lib/summary-retry-policy';
test('explicit recovery permits one old receipt-less step, never active or identified requests',()=>{
 const now=Date.now(), row={job_state:'uncertain',provider_id:null,attempt:0,started_at:new Date(now-600_000)};
 assert.equal(mayReplaceUnconfirmedStep(row,now),true);
 for(const change of [{job_state:'running'},{job_state:'completed'},{provider_id:'response-known'},{attempt:1},{started_at:new Date(now-599_999)},{started_at:null},{started_at:'invalid'}])assert.equal(mayReplaceUnconfirmedStep({...row,...change},now),false);
});
