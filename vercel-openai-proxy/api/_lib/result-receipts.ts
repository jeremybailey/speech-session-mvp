import {createHash} from 'node:crypto';
import {transaction} from './ledger';

export function receiptDigest(value:unknown):string {
  const digest=(value as {digest?:unknown})?.digest;
  if(typeof digest!=='string'||!/^[a-f0-9]{64}$/.test(digest)) throw new Error('invalid_request');
  return digest;
}
// A completed HTTP write does not prove delivery. Delete only after the client
// has durably saved the complete result and confirms its SHA-256 digest.
export async function acknowledgeResult(owner:string,id:string,digest:string,workflow=false) {
  return transaction(async db=>{
    // Serialize parent receipts so shared child deletion cannot miss both commits.
    // No inference transaction takes this lock; receipt transactions are short.
    await db.query("SELECT pg_advisory_xact_lock(842127903)");
    const table=workflow?'ai_condition_workflows':'ai_jobs';
    const row=(await db.query(`SELECT state,result_received_at FROM ${table} WHERE owner=$1 AND id=$2 FOR UPDATE`,[owner,id])).rows[0];
    if(!row) throw Object.assign(new Error('not_found'),{status:404});
    if(row.result_received_at) return {id,received:true};
    if(row.state!=='completed') throw Object.assign(new Error('result_not_completed'),{status:409});
    const payload=workflow
      ? (await db.query("SELECT (checkpoint->'result')::text AS output FROM ai_condition_workflow_payloads WHERE workflow_id=$1",[id])).rows[0]
      : (await db.query("SELECT result->>'output' AS output FROM ai_payloads WHERE job_id=$1",[id])).rows[0];
    // If expiry already removed the payload, there is no clinical result left
    // to compare or delete. Still record the receipt and purge dependent copies.
    if(payload && typeof payload.output!=='string') throw Object.assign(new Error('result_unavailable'),{status:410});
    if(payload && createHash('sha256').update(payload.output).digest('hex')!==digest)
      throw Object.assign(new Error('receipt_mismatch'),{status:409});
    await db.query(`UPDATE ${table} SET result_received_at=now() WHERE id=$1`,[id]);
    if(workflow) {
      await db.query('DELETE FROM ai_condition_workflow_payloads WHERE workflow_id=$1',[id]);
      await db.query(`DELETE FROM ai_condition_upload_parts p USING ai_condition_uploads u
        WHERE p.owner=u.owner AND p.digest=u.digest AND u.owner=$1 AND u.workflow_id=$2`,[owner,id]);
      // The upload digest is content-derived, so remove the upload identity too.
      await db.query('DELETE FROM ai_condition_uploads WHERE owner=$1 AND workflow_id=$2',[owner,id]);
    }
    const hasWorkflows=(await db.query("SELECT to_regclass('public.ai_condition_workflow_steps') AS name")).rows[0].name;
    if(hasWorkflows) {
      // A child may be shared by multiple parents or have a direct client receipt.
      // Never erase it while another retained parent can still need it to resume.
      await db.query(`DELETE FROM ai_payloads p USING ai_jobs j WHERE p.job_id=j.id AND j.owner=$1
        AND (j.result_received_at IS NOT NULL OR EXISTS (
          SELECT 1 FROM ai_condition_workflow_steps s JOIN ai_condition_workflows w ON w.id=s.workflow_id
          WHERE s.job_id=j.id AND w.result_received_at IS NOT NULL))
        AND NOT EXISTS (SELECT 1 FROM ai_condition_workflow_steps s
          JOIN ai_condition_workflow_payloads wp ON wp.workflow_id=s.workflow_id
          WHERE s.job_id=j.id)`,[owner]);
    } else {
      await db.query('DELETE FROM ai_payloads WHERE job_id=$1',[id]);
    }
    return {id,received:true};
  });
}
