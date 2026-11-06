import test from "node:test";
import assert from "node:assert/strict";
import {createServer} from "node:http";
import {readFile} from "node:fs/promises";
import {database, submitWithinTransaction, cleanup, transaction} from "../api/_lib/ledger";
import {runWholeHistory} from '../api/_lib/whole-history-background';
import {makePayload} from '../api/_lib/whole-history-source';
import {runJob, ProviderResponsePending} from "../api/_lib/worker";

test("background generation and overview survive redelivery; definitive rejection releases reservation without redispatch", {
  skip: !process.env.AI_PROVIDER_TEST_DATABASE_URL
}, async () => {
  const url=new URL(process.env.AI_PROVIDER_TEST_DATABASE_URL!);
  assert.match(url.pathname,/^\/cc_test_/);
  process.env.DATABASE_URL=url.href;
  process.env.AI_BUDGET_ID="evaluation-v1";
  process.env.AI_DEDUPE_SECRET="synthetic-test-secret";
  process.env.AI_DURABLE_ENABLED="true";
  process.env.AI_WHOLE_HISTORY_PROVIDER_BACKGROUND="true";
  delete process.env.AI_MOCK_INFERENCE;
  process.env.OPENAI_API_KEY="synthetic-provider-key";
  let mode="pending", posts=0, gets=0;
  const server=createServer(async(req,res)=>{
    for await (const chunk of req) { /* consume synthetic request */ }
    res.setHeader("content-type","application/json");
    if(req.method==="POST") {
      posts++;
      if(mode.startsWith("reject")) {
        res.statusCode=Number(mode.slice(6));
        res.end(JSON.stringify({error:{message:"Synthetic rejection",type:"invalid_request_error"}})); return;
      }
      if(mode==="ambiguous") {res.statusCode=503;res.end(JSON.stringify({error:{message:"Synthetic outage"}}));return;}
    } else { gets++; }
    res.end(JSON.stringify({id:"resp_synthetic_"+posts,object:"response",status:mode==="complete"?"completed":"queued",
      output:mode==="complete"?[{type:"message",role:"assistant",content:[{type:"output_text",text:"synthetic result",annotations:[]}]}]:[],
      usage:mode==="complete"?{input_tokens:10,output_tokens:5,total_tokens:15}:null}));
  });
  await new Promise<void>(r=>server.listen(0,"127.0.0.1",r));
  process.env.OPENAI_BASE_URL=`http://127.0.0.1:${(server.address() as {port:number}).port}/v1`;
  const db=database();
  const make=async(stage:string,input:string)=>{
    const client=await db.connect();
    try {await client.query("BEGIN");const job=await submitWithinTransaction(client,"synthetic-owner",{
      stage,instructions:"Synthetic only",input,response_format:{type:"json_schema",json_schema:{name:"fixture",strict:true,schema:{type:"object",properties:{},additionalProperties:false}}}
    } as never,"evaluation-v1","gpt-6-luna","medium");await client.query("COMMIT");return job;} finally {client.release();}
  };
  try {
    assert.equal((await db.query("SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema='public'")).rows[0].n,0);
    await db.query(await readFile("migrations/001_ai_ledger.sql","utf8"));
    await db.query("ALTER TABLE ai_jobs ADD COLUMN workload_type text NOT NULL DEFAULT 'unknown', ADD COLUMN reasoning_effort text NOT NULL DEFAULT 'low'");
    for(const stage of ["whole-history-generation","whole-history-overview"]) {
      mode="pending";const job=await make(stage,stage);const before=posts;
      await assert.rejects(runJob(job.id),ProviderResponsePending);
      await db.query("UPDATE ai_jobs SET started_at=now()-interval '6 minutes' WHERE id=$1",[job.id]);
      await cleanup();
      assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[job.id])).rows[0].state,"running");
      await assert.rejects(runJob(job.id),ProviderResponsePending);
      mode="complete";await runJob(job.id);await runJob(job.id);
      assert.equal(posts,before+1,"redelivery must never create another inference");
      assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[job.id])).rows[0].state,"completed");
    }
    assert.ok(gets>=4);
    for(const status of [400,401,403,404,413,422,429]) {
      mode="reject"+status;const job=await make("whole-history-overview",mode);const before=posts;
      await runJob(job.id);await runJob(job.id);
      const row=(await db.query("SELECT j.state,j.cost_nusd,p.result FROM ai_jobs j JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1",[job.id])).rows[0];
      assert.equal(row.state,"incomplete");assert.equal(row.cost_nusd,"0");
      assert.equal(row.result.diagnostics.providerHTTPStatus,status);
      assert.equal(posts,before+1);
    }
    // Real row locks serialize simultaneous explicit revalidation of one settled result.
    const records=[{id:'11111111-1111-4111-8111-111111111111',text:'Synthetic patient reports headache.'}];
    const payload=makePayload(records,JSON.parse(await readFile('api/_lib/whole-history-template.json','utf8'))).payload;
    const input=JSON.stringify({...JSON.parse(payload.input),serverOverview:true});
    mode='complete';const parent=await make('whole-history-generation',input);await runJob(parent.id);
    const proposal={concerns:[{id:'c1',name:'Headache',systems:['neurological'],evidence:['r1.p1']}],overview:[{text:'Headache.',cite:['r1.p1']}],passages:{'r1.p1':[{k:'symptoms',s:'reported',v:['Headache','',''],c:[],p:null,g:['c1'],m:null,f:[{key:'context',value:'Synthetic'},{key:'context',value:'headache'}]}]}};
    await db.query('UPDATE ai_payloads SET result=$2::jsonb WHERE job_id=$1',[parent.id,JSON.stringify({output:JSON.stringify(proposal),overview_error:'invalid_proposal'})]);
    const queued:string[]=[];const beforeRevalidation=posts;
    const runtime={database,transaction,submitWithinTransaction,runJob:async()=>{throw Error('generation_must_not_redispatch')},enqueueWholeHistory:async(id:string)=>{queued.push(id)}};
    await Promise.all([runWholeHistory(parent.id,runtime,true),runWholeHistory(parent.id,runtime,true)]);
    const repaired=(await db.query('SELECT result FROM ai_payloads WHERE job_id=$1',[parent.id])).rows[0].result;
    assert.equal(repaired.overview_error,undefined);assert.equal(repaired.overview_revalidation,'sole-evidence-link-v2');
    assert.ok(repaired.overviewJobID);assert.deepEqual(queued,[repaired.overviewJobID,repaired.overviewJobID]);assert.equal(posts,beforeRevalidation);
    assert.equal((await db.query("SELECT count(*)::int n FROM ai_jobs WHERE stage='whole-history-overview' AND state='queued'")).rows[0].n,1);
    await db.query("UPDATE ai_payloads SET expires_at=now()-interval '1 second' WHERE job_id=$1",[parent.id]);
    assert.equal(await runWholeHistory(parent.id,runtime,true),false);assert.equal(queued.length,2);
    await runJob(repaired.overviewJobID);
    assert.equal((await db.query("SELECT reserved_nusd FROM ai_budgets WHERE id='evaluation-v1'")).rows[0].reserved_nusd,"0");
    mode="ambiguous";const uncertain=await make("whole-history-overview","ambiguous");const before=posts;
    await assert.rejects(runJob(uncertain.id),/provider_receipt_pending/);
    await assert.rejects(runJob(uncertain.id),/job_running/);
    assert.equal(posts,before+1);
    assert.equal((await db.query("SELECT state FROM ai_jobs WHERE id=$1",[uncertain.id])).rows[0].state,"running");
    assert.ok(Number((await db.query("SELECT reserved_nusd FROM ai_budgets WHERE id='evaluation-v1'")).rows[0].reserved_nusd)>0);
  } finally {await db.end();await new Promise<void>(r=>server.close(()=>r()));}
});
