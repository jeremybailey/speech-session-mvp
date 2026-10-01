// Explicitly opted-in Preview build only. Never imports clinical fixtures or calls a model.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { database, submit, claim, settle, cancel, cleanup } from "../api/_lib/ledger";
import { reservation } from "../api/_lib/pricing";
import { readUsage } from "../api/v1/health-processing/usage";
import jobsHandler from "../api/v1/health-processing/jobs";
import { runJob } from "../api/_lib/worker";

async function main() {
  if (process.env.AI_PREVIEW_VERIFY !== "true") {
    console.log("Preview migration/check not requested; no database changes.");
    return;
  }
  assert.equal(process.env.VERCEL_ENV,"preview","Refusing to run outside Preview");
  assert.ok(process.env.AI_PREVIEW_QUEUE_VERIFY !== "true" && !process.env.AI_PREVIEW_QUEUE_TARGET_JOB,
    "Queue delivery must be tested through a ready deployment's runtime, not during a build");
  assert.equal(process.env.AI_MOCK_INFERENCE,"true","Mock inference must be explicit");
  assert.equal(process.env.AI_DURABLE_ENABLED,"true","Durable routing must be enabled for this Preview");
  for (const name of ["DATABASE_URL","AI_DEDUPE_SECRET","CRON_SECRET","KINDE_ISSUER_URL","KINDE_AUDIENCE"]) {
    assert.ok(process.env[name],`Missing required setting: ${name}`);
  }
  delete process.env.OPENAI_API_KEY;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = ((input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    if (url.hostname === "api.openai.com") throw new Error("Paid inference prohibited in Preview verification");
    return originalFetch(input,init);
  }) as typeof fetch;
  const db=database();
  try {
    // Existing unrelated application tables indicate an unexpected database target.
    const tables=(await db.query("SELECT tablename FROM pg_tables WHERE schemaname='public'")).rows.map(x=>x.tablename);
    assert.ok(tables.every(x=>["ai_budgets","ai_jobs","ai_payloads","ai_condition_workflows","ai_condition_workflow_payloads","ai_condition_workflow_steps"].includes(x)),"Unexpected database contents; migration refused");
    await db.query(await readFile("migrations/001_ai_ledger.sql","utf8"));
    await db.query(await readFile("migrations/002_condition_workflows.sql","utf8"));
    await db.query(await readFile("migrations/003_workflow_cost_attribution.sql","utf8"));
    await db.query(await readFile("migrations/004_workload_types.sql","utf8"));
    await db.query(await readFile("migrations/005_workflow_model.sql","utf8"));
    await db.query(await readFile("migrations/006_workflow_reasoning.sql","utf8"));
    assert.equal(Number((await db.query("SELECT limit_nusd FROM ai_budgets WHERE id='evaluation-v1'")).rows[0].limit_nusd),1_000_000_000);
    if(process.env.AI_PREVIEW_MIGRATE_ONLY==='true') {
      console.log('PASS additive Preview migrations only; no inference or smoke jobs submitted.');
      return;
    }
    assert.equal(Number((await db.query("SELECT count(*) FROM ai_jobs WHERE owner NOT LIKE 'synthetic-smoke:%'")).rows[0].count),0,
      "Refusing smoke tests in a database containing non-test jobs");
    console.log("PASS Preview migration; shared evaluation ceiling is $1 USD.");
    const run=randomUUID(), owner=`synthetic-smoke:${run}`, budget=`mock-${run}`;
    const reserve=reservation("gpt-4o-mini",6000);
    await db.query("INSERT INTO ai_budgets(id,limit_nusd) VALUES($1,$2)",[budget,reserve*2]);
    process.env.AI_BUDGET_ID=budget;
    const p={stage:"extraction",instructions:"Synthetic infrastructure test. No clinical information.",input:run,
      response_format:{type:"json_object"}};
    const submitted=await Promise.all(Array.from({length:8},()=>submit(owner,p)));
    assert.equal(new Set(submitted.map(j=>j.id)).size,1);
    const id=submitted[0].id;
    const claims=await Promise.all([claim(id),claim(id),claim(id)]);
    assert.equal(claims.filter(Boolean).length,1);
    assert.equal(claims.find(Boolean).id,id);
    await settle(id,"completed",{input_tokens:0,output_tokens:0},'{"synthetic":true}');
    assert.equal((await submit(owner,p)).state,"completed");
    assert.equal(await claim(id),null);
    const persisted=(await db.query("SELECT result FROM ai_payloads WHERE job_id=$1",[id])).rows[0].result;
    assert.equal(persisted.output,'{"synthetic":true}');
    console.log("PASS concurrent submission/claim, saved result and completed-result reuse.");
    const interrupted=await submit(owner,{...p,input:run+"-interrupted"});
    await claim(interrupted.id);
    await db.query("UPDATE ai_jobs SET started_at=now()-interval '10 minutes' WHERE id=$1",[interrupted.id]);
    await cleanup();
    assert.equal((await submit(owner,{...p,input:run+"-interrupted"})).state,"uncertain");
    assert.equal(await claim(interrupted.id),null);
    assert.equal(Number((await db.query("SELECT reserved_nusd FROM ai_budgets WHERE id=$1",[budget])).rows[0].reserved_nusd),reserve);
    console.log("PASS interrupted request remains reserved and is not redispatched.");
    const queued=await submit(owner,{...p,input:run+"-cancel"});
    await cancel("synthetic-smoke:other",queued.id);
    assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[queued.id])).rows[0].state,"queued");
    await assert.rejects(submit(owner,{...p,input:run+"-over-budget"}),/budget_exhausted/);
    await cancel(owner,queued.id);
    const mock=await submit(owner,{...p,input:run+"-worker"});
    let status=0;
    const response={status(code:number){status=code;return this;},json(){return this;},end(){return this;},setHeader(){return this;}};
    // Target this run's job; never claim another smoke run's queued work.
    assert.equal(await runJob(mock.id),1);
    assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[mock.id])).rows[0].state,"incomplete");
    console.log("PASS budget exhaustion, owner-scoped cancellation and actual mocked worker handler.");
    const usage=await readUsage(owner,"America/New_York");
    assert.equal(usage.lifetime_nusd,"0");
    assert.equal(usage.unresolved_charges,1);
    assert.ok(!JSON.stringify(usage).includes(p.instructions));
    assert.equal((await readUsage("synthetic-smoke:no-access","UTC")).entries.length,0);
    await jobsHandler({method:"GET",headers:{},query:{id}} as never,response as never);
    assert.equal(status,401);
    await db.query("UPDATE ai_payloads SET expires_at=now()-interval '1 second' WHERE job_id IN (SELECT id FROM ai_jobs WHERE owner=$1)",[owner]);
    await cleanup();
    assert.equal(Number((await db.query("SELECT count(*) FROM ai_payloads p JOIN ai_jobs j ON j.id=p.job_id WHERE j.owner=$1",[owner])).rows[0].count),0);
    console.log("PASS usage totals, owner isolation, missing-token rejection and clinical-payload expiration.");
    console.log("Preview database smoke verification complete. Paid API spend: $0. Synthetic ledger rows retained; no clinical content.");
  } finally { await db.end(); }
}
main().catch(error=>{console.error("Preview verification failed:",error instanceof assert.AssertionError ? error.message : "Database/configuration check failed; secret-bearing details suppressed.");process.exitCode=1;});
