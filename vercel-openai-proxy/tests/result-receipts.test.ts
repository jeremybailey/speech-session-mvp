import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {createHash,randomUUID} from 'node:crypto';
import {acknowledgeResult,receiptDigest} from '../api/_lib/result-receipts';
import {database,submit,claim,settle,transaction,submitWithinTransaction} from '../api/_lib/ledger';
const digest=(s:string)=>createHash('sha256').update(s).digest('hex');
const payload={stage:'classification',instructions:'Synthetic test only',input:'Synthetic source',response_format:{type:'json_object'}};
test('receipts accept only a SHA-256 digest',()=>{
  assert.equal(receiptDigest({digest:digest('result')}),digest('result'));
  for(const value of [null,{}, {digest:'clinical text'}, {digest:42}]) assert.throws(()=>receiptDigest(value));
});
test('receipt purge preserves ownership, costs, dedupe, complete delivery and shared dependencies',{
  skip:!process.env.AI_RECEIPT_TEST_DATABASE_URL,
},async()=>{
  const url=new URL(process.env.AI_RECEIPT_TEST_DATABASE_URL!);
  assert.ok(['127.0.0.1','localhost'].includes(url.hostname)&&url.pathname.startsWith('/cc_test_'));
  process.env.DATABASE_URL=url.href;process.env.AI_BUDGET_ID='evaluation-v1';process.env.AI_DEDUPE_SECRET='synthetic-only';
  const db=database();
  try {
    assert.equal((await db.query("SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema='public'")).rows[0].n,0);
    for(const file of (await readdir('migrations')).filter(f=>f.endsWith('.sql')).sort()) await db.query(await readFile(`migrations/${file}`,'utf8'));
    const job=await submit('alice',payload);
    await assert.rejects(()=>acknowledgeResult('alice',job.id,digest('result')),/result_not_completed/);
    await claim(job.id);await settle(job.id,'completed',{input_tokens:10,output_tokens:2},'result');
    const original=(await db.query('SELECT * FROM ai_jobs WHERE id=$1',[job.id])).rows[0];
    await assert.rejects(()=>acknowledgeResult('bob',job.id,digest('result')),/not_found/);
    await assert.rejects(()=>acknowledgeResult('alice',job.id,digest('partial result')),/receipt_mismatch/);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_payloads WHERE job_id=$1',[job.id])).rows[0].n,1);
    await Promise.all([acknowledgeResult('alice',job.id,digest('result')),acknowledgeResult('alice',job.id,digest('result'))]);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_payloads WHERE job_id=$1',[job.id])).rows[0].n,0);
    const after=(await db.query('SELECT * FROM ai_jobs WHERE id=$1',[job.id])).rows[0];
    assert.ok(after.result_received_at);assert.equal(after.cost_nusd,original.cost_nusd);assert.equal(after.request_hash,original.request_hash);
    assert.equal((await submit('alice',payload)).id,job.id);assert.equal(await claim(job.id),null);
    const child=await submit('alice',{...payload,input:'Shared synthetic source'});
    await claim(child.id);await settle(child.id,'completed',{input_tokens:10,output_tokens:2},'child result');
    const ids=[randomUUID(),randomUUID()];
    const checkpoint={result:{groups:[],unassigned:[]}};
    for(const id of ids) {
      await db.query(`INSERT INTO ai_condition_workflows(id,owner,request_hash,budget_id,state,record_count)
        VALUES($1,'alice',$2,'evaluation-v1','completed',1)`,[id,id]);
      await db.query('INSERT INTO ai_condition_workflow_payloads(workflow_id,plan,checkpoint) VALUES($1,$2,$3)',[id,{synthetic:true},checkpoint]);
      await db.query('INSERT INTO ai_condition_workflow_steps(workflow_id,revision,job_id) VALUES($1,0,$2)',[id,child.id]);
    }
    await db.query("INSERT INTO ai_condition_uploads(owner,digest,part_count,workflow_id) VALUES('alice',$1,1,$2)",[digest('upload'),ids[0]]);
    await db.query("INSERT INTO ai_condition_upload_parts(owner,digest,part_index,content) VALUES('alice',$1,0,'synthetic bytes')",[digest('upload')]);
    const output=(await db.query("SELECT (checkpoint->'result')::text AS output FROM ai_condition_workflow_payloads WHERE workflow_id=$1",[ids[0]])).rows[0].output;
    await assert.rejects(()=>acknowledgeResult('bob',ids[0],digest(output),true),/not_found/);
    await assert.rejects(()=>acknowledgeResult('alice',ids[0],digest('partial chunk'),true),/receipt_mismatch/);
    await acknowledgeResult('alice',ids[0],digest(output),true);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_payloads WHERE job_id=$1',[child.id])).rows[0].n,1,'Other parent still needs child');
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_condition_uploads')).rows[0].n,0);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_condition_upload_parts')).rows[0].n,0);
    await acknowledgeResult('alice',ids[1],digest(output),true);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_payloads WHERE job_id=$1',[child.id])).rows[0].n,0);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_condition_workflow_payloads')).rows[0].n,0);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_condition_workflow_steps')).rows[0].n,2,'Accounting links remain');
    await acknowledgeResult('alice',ids[1],digest(output),true);
    const newParent = randomUUID();
    const replacement = await transaction(db=>submitWithinTransaction(db,'alice',payload,'evaluation-v1','gpt-4o-mini','low',newParent));
    assert.notEqual(replacement.id,job.id,'New parent needs its own inference after old content was purged');
    const retry = await transaction(db=>submitWithinTransaction(db,'alice',payload,'evaluation-v1','gpt-4o-mini','low',newParent));
    assert.equal(retry.id,replacement.id,'Parent retry cannot create another paid job');
    assert.equal((await submit('alice',payload)).id,job.id,'Direct retry still returns its receipt tombstone');
    // Restore synthetic parent/child payloads to test concurrent receipt ordering.
    await db.query('UPDATE ai_condition_workflows SET result_received_at=NULL');
    for(const id of ids) await db.query('INSERT INTO ai_condition_workflow_payloads(workflow_id,plan,checkpoint) VALUES($1,$2,$3)',[id,{synthetic:true},checkpoint]);
    await db.query('INSERT INTO ai_payloads(job_id,payload,result) VALUES($1,$2,$3)',[child.id,payload,{output:'child result'}]);
    await Promise.all(ids.map(id=>acknowledgeResult('alice',id,digest(output),true)));
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ai_payloads WHERE job_id=$1',[child.id])).rows[0].n,0,'Concurrent final receipts purge shared content');
  } finally {await db.end();}
});
