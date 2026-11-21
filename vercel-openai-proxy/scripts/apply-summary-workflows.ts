import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {Pool} from 'pg';
async function main(){
 if(process.env.AI_APPLY_SUMMARY_WORKFLOWS!=='1')return;
 assert.ok(process.env.DATABASE_URL);
 const pool=new Pool({connectionString:process.env.DATABASE_URL,max:1,connectionTimeoutMillis:10000});
 try {
  assert.ok((await pool.query("SELECT to_regclass('public.ai_jobs') name")).rows[0].name,'Existing durable ledger required');
  await pool.query(await readFile(new URL('../migrations/013_summary_workflows.sql',import.meta.url),'utf8'));
  console.log('Summary workflow migration applied; clinical processing remains controlled by release flags.');
 }finally{await pool.end();}
}
main().catch(()=>{console.error('Summary migration failed; sensitive connection details suppressed.');process.exitCode=1;});
