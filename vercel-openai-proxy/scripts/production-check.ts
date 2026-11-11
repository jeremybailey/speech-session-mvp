// Read-only deployment gate: no clinical payloads, migrations, or inference.
import assert from 'node:assert/strict';
import {pilotAgreement} from '../api/_lib/pilot-agreement';
import {database} from '../api/_lib/ledger';
import {conditionModel,conditionReasoning,summaryModelPolicy} from '../api/_lib/model-policy';
let checkpoint = 'configuration';
async function main() {
  if(process.env.VERCEL_ENV!=='production'||process.env.AI_DURABLE_ENABLED!=='true') return;
  assert.equal(process.env.AI_MOCK_INFERENCE,'false');
  assert.equal(process.env.AI_QUEUE_ENABLED,'true');
  assert.equal(process.env.AI_CONDITION_WORKFLOWS_ENABLED,'true');
  assert.deepEqual(summaryModelPolicy('extraction'),{model:'gpt-6-luna',effort:'medium'});
  assert.deepEqual(summaryModelPolicy('checking'),{model:'gpt-6-luna',effort:'medium'});
  assert.deepEqual(summaryModelPolicy('classification'),{model:'gpt-4o-mini',effort:'low'});
  assert.equal(conditionModel(),'gpt-6-luna');assert.equal(conditionReasoning(),'medium');
  for(const name of ['DATABASE_URL','AI_DEDUPE_SECRET','CRON_SECRET','KINDE_ISSUER_URL','KINDE_AUDIENCE','OPENAI_API_KEY']) assert.ok(process.env[name],`Missing ${name}`);
  assert.equal(process.env.PILOT_AGREEMENT_VERSION,pilotAgreement.version,'Published agreement version must be enabled');
  const db=database();
  try {
    checkpoint = 'agreement-table';
    assert.ok((await db.query("SELECT to_regclass('public.pilot_agreement_acceptances') AS name")).rows[0].name,'Agreement migration missing');
    checkpoint = 'chunked-upload-table';
    assert.ok((await db.query("SELECT to_regclass('public.ai_condition_upload_parts') AS name")).rows[0].name,'Chunked-upload migration missing');
    if(process.env.AI_INCREMENTAL_RECORDS_ENABLED==='true') {
      checkpoint = 'incremental-background';
      assert.equal(process.env.AI_WHOLE_HISTORY_PROVIDER_BACKGROUND,'true');
      for(const [table,column] of [['ai_record_units','validator_version'],['ai_record_units','next_attempt_at'],['ai_record_updates','last_woken_at']]) {
        checkpoint='incremental:'+table+'.'+column;
        assert.equal((await db.query('SELECT 1 FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 AND column_name=$3',['public',table,column])).rows.length,1,'Incremental migration missing');
      }
    }
    checkpoint = 'shared-budget';
    const budget=(await db.query('SELECT limit_nusd,used_nusd,reserved_nusd FROM ai_budgets WHERE id=$1',[process.env.AI_BUDGET_ID])).rows[0];
    assert.ok(budget&&BigInt(budget.limit_nusd)<=(process.env.STORY_LAB_ENABLED==='true'?10000000000n:20000000000n),'Shared ceiling exceeds approved allowance');
    if(process.env.STORY_LAB_ENABLED==='true')assert.ok((await db.query("SELECT to_regclass('public.ai_story_operations') AS name")).rows[0].name,'Story migration missing');
    checkpoint = 'shared-budget-remaining';
    assert.ok(BigInt(budget.used_nusd)+BigInt(budget.reserved_nusd)<BigInt(budget.limit_nusd),'Pilot budget exhausted');
    for(const [table,column] of [['ai_jobs','result_received_at'],['ai_condition_workflows','result_received_at'],['ai_jobs','reasoning_effort'],['ai_jobs','workload_type'],['ai_condition_workflows','model'],['ai_condition_workflows','reasoning_effort'],['ai_condition_workflow_steps','incurs_cost']]) {
      checkpoint = 'column:' + table + '.' + column;
      assert.equal((await db.query('SELECT 1 FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 AND column_name=$3',['public',table,column])).rows.length,1,'Required migration missing');
    }
    console.log('PASS production readiness: Kinde-authenticated alpha, migrated ledger, Luna medium, shared budget intact; no inference.');
  } finally {await db.end();}
}
main().catch(()=>{console.error('Production readiness failed at ' + checkpoint + '; secret-bearing details suppressed.');process.exitCode=1;});
