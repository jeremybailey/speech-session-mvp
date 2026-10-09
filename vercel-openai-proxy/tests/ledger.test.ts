import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { estimate, reservation } from "../api/_lib/pricing";
import { submit, claim, settle, cancel, cancelPayload, cleanup, database, requestHash, validatePayload } from "../api/_lib/ledger";
import { readUsage } from "../api/v1/health-processing/usage";
import continueHandler from "../api/v1/health-processing/continue";
import { runJob } from "../api/_lib/worker";
import { queueJobID, enqueueJob } from "../api/_lib/queue";
import { modelOptions, summaryModelPolicy } from '../api/_lib/model-policy';

test('summary evaluation policy pins extraction and checking to Luna medium', () => {
  for (const stage of ['extraction','checking']) {
    const selected=summaryModelPolicy(stage);
    assert.deepEqual(selected,{model:'gpt-6-luna',effort:'medium'});
    assert.equal(reservation(selected.model,6000),214500000);
  }
  for (const stage of ['classification','duplicates','overview']) {
    assert.deepEqual(summaryModelPolicy(stage),{model:'gpt-4o-mini',effort:'low'});
  }
});
const payload = {stage:"classification",instructions:"Synthetic fixture only",input:"fixture-1",
  response_format:{type:"json_schema",json_schema:{name:"fixture",strict:true,
    schema:{type:"object",properties:{},additionalProperties:false}}}};
test("pricing counts cached input and never treats absent usage as zero", () => {
  assert.equal(estimate("gpt-4o-mini",{input_tokens:1000,output_tokens:100,input_tokens_details:{cached_tokens:500}}),172500);
  assert.equal(estimate("gpt-4o-mini"),null);
  assert.equal(estimate("gpt-4o-mini",{input_tokens:2,output_tokens:NaN}),null);
  assert.throws(() => estimate("unknown",{input_tokens:0,output_tokens:0}));
  assert.ok(reservation("gpt-4o-mini",6000) > 0);
  assert.equal(estimate('gpt-6-luna',{input_tokens:1000,output_tokens:100}),150000);
  assert.equal(estimate('gpt-6-luna',{input_tokens:272001,output_tokens:100}),54475200);
  assert.equal(reservation('gpt-6-luna',6000),214500000);
  assert.throws(()=>estimate('gpt-6-luna',undefined,'2026-09-29-v1'));
  assert.throws(()=>estimate('gpt-4o-mini',undefined,'unknown'));
  assert.deepEqual(modelOptions('gpt-6-luna'),{reasoning:{effort:'low'},prompt_cache_options:{mode:'explicit'}});
});
test("canonical dedupe ignores transient request IDs, isolates owners and changed source", () => {
  process.env.AI_DEDUPE_SECRET="synthetic-test-secret";
  const parsed = validatePayload({...payload,request_id:"transient"});
  assert.equal(requestHash("user-a",parsed),requestHash("user-a",validatePayload(payload)));
  assert.notEqual(requestHash("user-a",parsed),requestHash("user-b",parsed));
  assert.notEqual(requestHash("user-a",parsed),requestHash("user-a",{...parsed,input:"changed"}));
  assert.equal(requestHash('user-a',parsed),requestHash('user-a',{...parsed,workload_type:'development'}));
  assert.notEqual(requestHash('user-a',parsed),requestHash('user-a',parsed,'gpt-6-luna'));
  assert.notEqual(requestHash('user-a',parsed,'gpt-6-luna','low'),requestHash('user-a',parsed,'gpt-6-luna','medium'));
  assert.throws(() => validatePayload({...payload,stage:"arbitrary-clinical-text"}));
});
test("queue carries only an opaque job ID and stays disabled by default", async () => {
  const id="1c1bdde8-f0c4-4a3c-bb1f-ffcced2c991b";
  assert.equal(queueJobID({id}),id);
  assert.throws(()=>queueJobID({id,clinicalText:"must not enter a queue"}));
  assert.throws(()=>queueJobID({id:"not a UUID"}));
  delete process.env.AI_QUEUE_ENABLED;
  await enqueueJob(id); // Must not need OIDC credentials or perform network I/O.
});
test("PostgreSQL concurrency, completed reuse, uncertain charges, cancellation, expiry and quota", {
  skip: !process.env.AI_TEST_DATABASE_URL,
}, async () => {
  // This must be a dedicated empty test database; never run migrations against production.
  process.env.DATABASE_URL=process.env.AI_TEST_DATABASE_URL;
  process.env.AI_BUDGET_ID="evaluation-v1";
  process.env.AI_DEDUPE_SECRET="synthetic-test-secret";
  const db=database();
  try {
    assert.equal((await db.query("SELECT count(*)::int AS count FROM information_schema.tables WHERE table_schema='public'")).rows[0].count,0,
      "Use a new empty database for each run");
    await db.query(await readFile("migrations/001_ai_ledger.sql","utf8"));
    // This suite intentionally omits workflow tables to exercise staged deployment compatibility.
    await db.query("ALTER TABLE ai_jobs ADD COLUMN workload_type text NOT NULL DEFAULT 'unknown'");
    await db.query("ALTER TABLE ai_jobs ADD COLUMN reasoning_effort text NOT NULL DEFAULT 'low'");
    const jobs=await Promise.all(Array.from({length:12},()=>submit("user-a",payload)));
    assert.equal(new Set(jobs.map(x=>x.id)).size,1);
    const claims=await Promise.all([claim(),claim(),claim()]);
    assert.equal(claims.filter(Boolean).length,1);
    await settle(jobs[0].id,"completed",{input_tokens:100,output_tokens:20},"synthetic-result");
    const firstUsage = await readUsage("user-a","America/New_York");
    assert.equal(firstUsage.lifetime_nusd,String(estimate("gpt-4o-mini",{input_tokens:100,output_tokens:20})));
    assert.equal(firstUsage.today_nusd,firstUsage.lifetime_nusd);
    assert.equal(firstUsage.last48_nusd,firstUsage.lifetime_nusd);
    assert.equal((await readUsage("other-user","UTC")).entries.length,0);
    assert.equal((await readUsage("other-user","UTC")).tracking_start,null);
    assert.ok(!JSON.stringify(firstUsage).includes("synthetic-result"));
    assert.ok(!JSON.stringify(firstUsage).includes("Synthetic fixture"));
    for (const timezone of ["Pacific/Kiritimati","America/Los_Angeles","Asia/Kolkata"]) {
      await db.query(`UPDATE ai_jobs SET created_at=(date_trunc('day',now() AT TIME ZONE $2) AT TIME ZONE $2)-interval '1 second' WHERE id=$1`,[jobs[0].id,timezone]);
      await db.query("UPDATE ai_jobs SET started_at=created_at WHERE id=$1",[jobs[0].id]);
      assert.equal((await readUsage("user-a",timezone)).today_nusd,"0");
      await db.query(`UPDATE ai_jobs SET created_at=(date_trunc('day',now() AT TIME ZONE $2) AT TIME ZONE $2)+interval '1 second' WHERE id=$1`,[jobs[0].id,timezone]);
      await db.query("UPDATE ai_jobs SET started_at=created_at WHERE id=$1",[jobs[0].id]);
      assert.equal((await readUsage("user-a",timezone)).today_nusd,firstUsage.lifetime_nusd);
    }
    await db.query("UPDATE ai_jobs SET created_at=now()-interval '49 hours' WHERE id=$1",[jobs[0].id]);
    await db.query("UPDATE ai_jobs SET started_at=created_at WHERE id=$1",[jobs[0].id]);
    assert.equal((await readUsage("user-a","UTC")).last48_nusd,"0");
    assert.equal((await submit("user-a",payload)).state,"completed");
    assert.equal(await claim(),null);
    const uncertain=await submit("user-a",{...payload,input:"network interrupted"});
    await claim(); await settle(uncertain.id,"uncertain");
    const held=(await db.query("SELECT reserved_nusd FROM ai_budgets WHERE id='evaluation-v1'")).rows[0];
    assert.equal(Number(held.reserved_nusd),reservation("gpt-4o-mini",6000));
    assert.equal((await submit("user-a",{...payload,input:"network interrupted"})).state,"uncertain");
    assert.equal((await readUsage("user-a","UTC")).unresolved_charges,1);
    const cancelled=await submit("user-a",{...payload,input:"cancel"});
    await cancel("other-user",cancelled.id);
    assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[cancelled.id])).rows[0].state,"queued");
    await cancel("user-a",cancelled.id);
    assert.equal(await claim(),null);
    const interrupted=await submit("user-a",{...payload,input:"worker killed"});
    await claim();
    await db.query("UPDATE ai_jobs SET started_at=now()-interval '10 minutes' WHERE id=$1",[interrupted.id]);
    await cleanup();
    assert.equal((await submit("user-a",{...payload,input:"worker killed"})).state,"uncertain");
    const expired=await submit("user-a",{...payload,input:"expired payload"});
    await db.query("UPDATE ai_payloads SET expires_at=now()-interval '1 second'");
    await cleanup();
    assert.equal((await db.query("SELECT count(*)::int AS count FROM ai_payloads")).rows[0].count,0);
    assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[expired.id])).rows[0].state,"expired");
    assert.equal((await db.query("SELECT count(*)::int AS count FROM ai_jobs")).rows[0].count,5);
    process.env.AI_DURABLE_ENABLED="true";
    process.env.AI_MOCK_INFERENCE="true";
    process.env.CRON_SECRET="synthetic-cron-secret";
    const mock=await submit("user-a",{...payload,input:"mock worker routing"});
    let status=0;
    const response={status(code:number){status=code;return this;},json(){return this;},end(){return this;}};
    await continueHandler({method:"POST",headers:{authorization:"Bearer synthetic-cron-secret"}} as never,response as never);
    assert.equal(status,200);
    assert.equal((await db.query("SELECT state,cost_nusd FROM ai_jobs WHERE id=$1",[mock.id])).rows[0].state,"incomplete");
    const first=await submit("user-a",{...payload,input:"targeted queue first"});
    const second=await submit("user-a",{...payload,input:"targeted queue second"});
    assert.equal(await runJob(second.id),1);
    assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[first.id])).rows[0].state,"queued",
      "Queue delivery must not claim another job");
    assert.equal(await runJob(second.id),0,"Redelivery must not dispatch again");
    await cancel("user-a",first.id);
    assert.equal(await runJob(first.id),0,"Cancelled queued work must not run");
    const abandoned=await submit("user-a",{...payload,input:"targeted worker interruption"});
    await claim(abandoned.id);
    await assert.rejects(runJob(abandoned.id),/job_running/);
    await db.query("UPDATE ai_jobs SET started_at=now()-interval '10 minutes' WHERE id=$1",[abandoned.id]);
    assert.equal(await runJob(abandoned.id),0);
    assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[abandoned.id])).rows[0].state,"uncertain");
    await db.query("UPDATE ai_budgets SET limit_nusd=used_nusd+reserved_nusd");
    const stoppedPayload={...payload,input:'Stop before POST with exhausted budget'};
    const stopped=await cancelPayload('user-a',stoppedPayload);
    assert.equal(stopped.state,'cancelled');
    assert.equal((await submit('user-a',stoppedPayload)).id,stopped.id);
    assert.equal(await claim(stopped.id),null);
    assert.equal((await db.query('SELECT cost_nusd FROM ai_jobs WHERE id=$1',[stopped.id])).rows[0].cost_nusd,'0');
    const attempts=await Promise.allSettled([submit("user-a",{...payload,input:"over budget"}),submit("user-b",payload)]);
    assert.ok(attempts.every(x=>x.status==="rejected"));
  } finally { await db.end(); }
});
