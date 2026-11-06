import {readFile} from 'node:fs/promises';
import {database,transaction} from '../api/_lib/ledger';
async function main(){
 if(process.env.MIGRATE_INCREMENTAL_RECORDS!=='1')return;
 try{await transaction(async db=>{
  await db.query("SELECT pg_advisory_xact_lock(hashtext('incremental-migration-010'))");
  await db.query(await readFile('migrations/010_incremental_updates.sql','utf8'));
  await db.query(await readFile('migrations/011_record_runtime.sql','utf8'));
 });console.log('Incremental migrations 010/011 applied. No clinical records modified.');}
 finally{await database().end();}
}
main().catch(()=>{console.error('Incremental migration failed');process.exitCode=1;});
