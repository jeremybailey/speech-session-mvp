// Read-only deployment gate: no clinical payloads, migrations, or inference.
import assert from 'node:assert/strict';
import {database} from '../api/_lib/ledger';
import {conditionModel,conditionReasoning} from '../api/_lib/model-policy';
async function main() {
  if(process.env.VERCEL_ENV!=='production'||process.env.AI_DURABLE_ENABLED!=='true') return;
  assert.equal(process.env.AI_MOCK_INFERENCE,'false');
  assert.equal(process.env.AI_QUEUE_ENABLED,'true');
  assert.equal(process.env.AI_CONDITION_WORKFLOWS_ENABLED,'true');
  assert.equal(conditionModel(),'gpt-6-luna');assert.equal(conditionReasoning(),'medium');
  for(const name of ['DATABASE_URL','AI_DEDUPE_SECRET','CRON_SECRET','KINDE_ISSUER_URL','KINDE_AUDIENCE','OPENAI_API_KEY']) assert.ok(process.env[name],`Missing ${name}`);
  const db=database();
  try {
    assert.ok((await db.query("SELECT to_regclass('public.ai_condition_upload_parts') AS name")).rows[0].name,'Chunked-upload migration missing');
    const budget=(await db.query('SELECT limit_nusd,used_nusd,reserved_nusd FROM ai_budgets WHERE id=$1',[process.env.AI_BUDGET_ID])).rows[0];
    assert.ok(budget&&BigInt(budget.limit_nusd)<=1000000000n,'Shared pilot ceiling must not exceed $1');
    assert.ok(BigInt(budget.used_nusd)+BigInt(budget.reserved_nusd)<BigInt(budget.limit_nusd),'Pilot budget exhausted');
    for(const [table,column] of [['ai_jobs','reasoning_effort'],['ai_jobs','workload_type'],['ai_condition_workflows','model'],['ai_condition_workflows','reasoning_effort'],['ai_condition_workflow_steps','incurs_cost']]) {
      assert.equal((await db.query('SELECT 1 FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 AND column_name=$3',['public',table,column])).rows.length,1,'Required migration missing');
    }
    console.log('PASS production readiness: Kinde-authenticated alpha, migrated ledger, Luna medium, shared budget intact; no inference.');
  } finally {await db.end();}
}
main().catch(()=>{console.error('Production readiness failed; secret-bearing details suppressed.');process.exitCode=1;});
