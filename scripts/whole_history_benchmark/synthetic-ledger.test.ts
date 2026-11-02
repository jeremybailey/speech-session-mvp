import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {database,transaction,submitWithinTransaction,claim,settle,cancel} from './api/_lib/ledger';
import {outputTokenLimit} from './api/_lib/output-policy';
const config=require('./api/config.json');
test('synthetic admission, duplicate, cancel, uncertain and exhaustion (no provider calls)',async()=>{
 const url=new URL(process.env.DATABASE_URL!);assert.ok(url.hostname==='127.0.0.1'&&url.pathname.startsWith('/cc_test_'));
 process.env.AI_DEDUPE_SECRET='synthetic-only';process.env.AI_BUDGET_ID='evaluation-v1';
 const db=database(),owner=config.prefix+(config.runVersion??'')+'baseline-1';
 const p={stage:'checking',instructions:'Synthetic',input:'Synthetic record',response_format:{type:'json_object'}};
 const submit=(input:string)=>transaction(client=>submitWithinTransaction(client,owner,{...p,input},undefined,'gpt-6-luna','medium'));
 try{
  for(const f of ['001_ai_ledger.sql','002_condition_workflows.sql','003_workflow_cost_attribution.sql','004_workload_types.sql','005_workflow_model.sql','006_workflow_reasoning.sql','007_condition_uploads.sql'])await db.query(await readFile(process.env.BENCHMARK_MIGRATIONS+'/'+f,'utf8'));
  await db.query("UPDATE ai_budgets SET limit_nusd=20000000000 WHERE id='evaluation-v1'");
  const first=await submit('duplicate');const all=await Promise.all(Array.from({length:10},()=>submit('duplicate')));assert.ok(all.every(j=>j.id===first.id));
  await cancel(owner,first.id);assert.equal((await submit('duplicate')).id,first.id);
  assert.equal((await db.query('SELECT state,cost_nusd FROM ai_jobs WHERE id=$1',[first.id])).rows[0].state,'cancelled');
  const u=await submit('uncertain');assert.ok(await claim(u.id));assert.equal(await claim(u.id),null);await settle(u.id,'uncertain');assert.equal((await submit('uncertain')).id,u.id);
  const retained=(await db.query('SELECT reserved_nusd FROM ai_budgets')).rows[0].reserved_nusd;assert.ok(BigInt(retained)>0n);
  assert.equal(outputTokenLimit('gpt-6-luna','whole-history-generation'),64000);assert.equal(outputTokenLimit('gpt-6-luna','extraction'),10000);
  const c=await submit('complete');assert.ok(await claim(c.id));await settle(c.id,'completed',{input_tokens:100,output_tokens:10},'{}');assert.equal((await submit('complete')).id,c.id);
  const unrelatedBefore=(await db.query('SELECT limit_nusd FROM ai_budgets')).rows[0].limit_nusd;
  await db.query('UPDATE ai_jobs SET cost_nusd=4800000000,owner=$2 WHERE id=$1',[c.id,config.prefix+'prior-trial:baseline-1']);
  await assert.rejects(()=>submit('exhausted'),/experiment_budget_exhausted/);
  assert.equal((await db.query('SELECT limit_nusd FROM ai_budgets')).rows[0].limit_nusd,unrelatedBefore);
  assert.ok(BigInt((await db.query('SELECT reserved_nusd FROM ai_budgets')).rows[0].reserved_nusd)>0n,'Uncertain reservation retained');
 }finally{await db.end()}
});
