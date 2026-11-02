// Explicit one-deployment opt-in. Add nullable receipt metadata only; no inference.
import assert from 'node:assert/strict';
import {Pool} from 'pg';
async function main() {
 if(process.env.AI_APPLY_RESULT_RECEIPTS!=='1')return;
 assert.equal(process.env.VERCEL_ENV,'production');
 assert.ok(process.env.DATABASE_URL);
 const pool=new Pool({connectionString:process.env.DATABASE_URL,max:1,connectionTimeoutMillis:10000});
 const db=await pool.connect();
 try {
  await db.query('BEGIN');
  assert.ok((await db.query("SELECT to_regclass('public.ai_jobs') name")).rows[0].name);
  assert.ok((await db.query("SELECT to_regclass('public.ai_condition_workflows') name")).rows[0].name);
  await db.query('ALTER TABLE ai_jobs ADD COLUMN IF NOT EXISTS result_received_at timestamptz');
  await db.query('ALTER TABLE ai_condition_workflows ADD COLUMN IF NOT EXISTS result_received_at timestamptz');
  await db.query('COMMIT');
  console.log('PASS additive receipt metadata migration; no records, jobs, reservations or budget totals changed.');
 }catch(error){await db.query('ROLLBACK');throw error;}
 finally{db.release();await pool.end();}
}
main().catch(()=>{console.error('Receipt migration failed; secret-bearing details suppressed.');process.exitCode=1;});
