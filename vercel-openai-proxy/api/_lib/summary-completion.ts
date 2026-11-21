import { database } from './ledger';

/** A provider receipt wakes the existing parent; it never creates inference.
 * Keeping the notification in the outbox survives queue publication failure.
 * Duplicate receipts cannot bypass a workflow's retry backoff. */
export async function wakeSummaryForChild(jobID: string, db = database()): Promise<boolean> {
  if (process.env.AI_SUMMARY_WORKFLOWS_ENABLED !== 'true') return false;
  const result = await db.query(`
    INSERT INTO ai_summary_outbox(workflow_id,available_at)
    SELECT w.id,GREATEST(now(),COALESCE(w.retry_at,now()))
    FROM ai_summary_children c JOIN ai_summary_workflows w ON w.id=c.workflow_id
    JOIN ai_summary_steps s ON s.workflow_id=w.id AND s.job_id=c.job_id
    WHERE c.job_id=$1 AND s.state='running'
      AND w.state IN ('queued','running','retry_scheduled') AND w.expires_at>now()
    ON CONFLICT(workflow_id) DO UPDATE
      SET available_at=LEAST(ai_summary_outbox.available_at,EXCLUDED.available_at),
          lease_until=NULL,fence=ai_summary_outbox.fence+1
    RETURNING workflow_id`, [jobID]);
  return result.rows.length > 0;
}
