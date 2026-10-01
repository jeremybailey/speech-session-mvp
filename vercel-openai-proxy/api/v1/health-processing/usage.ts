import type { VercelRequest, VercelResponse } from "@vercel/node";
import { verifyKindeBearer } from "../../_lib/verifyKinde";
import { transaction } from "../../_lib/ledger";
import { durableEnabledForOwner } from '../../_lib/pilot';

export async function readUsage(owner: string, timezone: string) {
  return transaction(async db => {
    await db.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY");
    const totals = (await db.query(`SELECT min(created_at) AS tracking_start,now() AS updated_at,
      coalesce(sum(cost_nusd),0)::text AS lifetime_nusd,
      coalesce(sum(cost_nusd) FILTER (WHERE coalesce(started_at,created_at)>=now()-interval '48 hours'),0)::text AS last48_nusd,
      coalesce(sum(cost_nusd) FILTER (WHERE coalesce(started_at,created_at)>=date_trunc('day',now() AT TIME ZONE $2) AT TIME ZONE $2),0)::text AS today_nusd,
      count(*) FILTER (WHERE state='uncertain')::int AS unresolved_charges
      FROM ai_jobs WHERE owner=$1`,[owner,timezone])).rows[0];
    // Explicit projection: no clinical data, user-supplied labels, or provider errors.
    const entries = (await db.query(`SELECT id,stage,model,state,cost_nusd::text,reserve_nusd::text,
      coalesce(to_jsonb(j)->>'workload_type','unknown') AS workload_type,
      retry_count,record_count,created_at FROM ai_jobs j WHERE owner=$1 ORDER BY created_at DESC`,[owner])).rows;
    const hasWorkflows=Boolean((await db.query("SELECT to_regclass('public.ai_condition_workflows') AS name")).rows[0].name);
    const budgets = (await db.query(`SELECT b.id,b.limit_nusd::text,b.used_nusd::text,b.reserved_nusd::text
      FROM ai_budgets b WHERE EXISTS (SELECT 1 FROM ai_jobs j WHERE j.budget_id=b.id AND j.owner=$1)
      ${hasWorkflows?'OR EXISTS (SELECT 1 FROM ai_condition_workflows w WHERE w.budget_id=b.id AND w.owner=$1)':''}`,[owner])).rows;
    // Keep deployment backward compatible until the additive workflow migration lands.
    let latest_job = entries[0] ?? null;
    if (hasWorkflows) {
      const attributed=Boolean((await db.query(`SELECT 1 FROM information_schema.columns WHERE table_schema='public'
        AND table_name='ai_condition_workflow_steps' AND column_name='incurs_cost'`)).rows.length);
      const cost=attributed?`CASE WHEN count(j.id) FILTER (WHERE s.incurs_cost IS NULL OR (s.incurs_cost AND j.cost_nusd IS NULL))>0 THEN NULL
        ELSE coalesce(sum(j.cost_nusd) FILTER (WHERE s.incurs_cost),0)::text END`:
        `CASE WHEN count(j.id)>0 THEN NULL ELSE '0' END`;
      const workflow = (await db.query(`SELECT w.id,w.state,w.record_count,w.created_at,
        coalesce(to_jsonb(w)->>'workload_type','unknown') AS workload_type,
        ${cost} AS cost_nusd,
        coalesce(sum(j.retry_count),0)::int AS retry_count,
        count(j.id) FILTER (WHERE j.state='uncertain')::int AS unresolved_charges
        FROM ai_condition_workflows w
        LEFT JOIN (SELECT workflow_id,job_id${attributed?',CASE WHEN bool_or(incurs_cost) THEN true WHEN bool_or(incurs_cost IS NULL) THEN NULL ELSE false END AS incurs_cost':''}
          FROM ai_condition_workflow_steps GROUP BY workflow_id,job_id) s ON s.workflow_id=w.id
        LEFT JOIN ai_jobs j ON j.id=s.job_id AND j.owner=w.owner
        WHERE w.owner=$1 GROUP BY w.id ORDER BY w.created_at DESC LIMIT 1`,[owner])).rows[0];
      // A later independent request can still be the latest job; workflow child requests cannot.
      const independent = (await db.query(`SELECT j.id,j.state,j.record_count,j.created_at,
        coalesce(to_jsonb(j)->>'workload_type','unknown') AS workload_type,
        j.cost_nusd::text,j.retry_count FROM ai_jobs j WHERE j.owner=$1 AND NOT EXISTS
        (SELECT 1 FROM ai_condition_workflow_steps s WHERE s.job_id=j.id)
        ORDER BY j.created_at DESC LIMIT 1`,[owner])).rows[0];
      latest_job = workflow && (!independent || new Date(workflow.created_at) >= new Date(independent.created_at))
        ? workflow : independent ?? null;
    }
    return {...totals,entries,budgets,latest_job};
  });
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader("Cache-Control","no-store");
  if (req.method !== "GET") return res.status(405).end();
  try {
    const owner = await verifyKindeBearer(req.headers.authorization);
    const timezone = typeof req.query.timezone === "string" ? req.query.timezone : "UTC";
    try { new Intl.DateTimeFormat("en-US",{timeZone:timezone}); } catch { return res.status(400).end(); }
    const result = await readUsage(owner,timezone);
    return res.status(200).json({...result,currency:"USD",timezone,processing_enabled:durableEnabledForOwner(owner),
      historical_status:"Historical charges before tracking are unavailable. Provider billing is authoritative.",
      budget_scope:"Shared pilot budget; includes all participating accounts."});
  } catch (cause) {
    return res.status((cause as {status?:number}).status ?? 503).json({error:{code:"usage_unavailable"}});
  }
}
