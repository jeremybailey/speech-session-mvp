import type { VercelRequest, VercelResponse } from "@vercel/node";
import { cleanup, database } from "../../_lib/ledger";
import { cleanupConditionWorkflows } from "../../_lib/condition-workflow-store";

/** Retention maintenance must keep running even when paid processing is disabled. */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader("Cache-Control", "no-store");
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) return res.status(401).end();
  if (req.method !== "GET" && req.method !== "POST") return res.status(405).end();
  try {
    // Retention continues after disabling the pilot, and remains compatible with
    // deployments where the additive workflow migration has not run yet.
    if((await database().query("SELECT to_regclass('public.ai_condition_workflows') AS name")).rows[0].name) await cleanupConditionWorkflows();
    await cleanup(); return res.status(200).json({ cleaned: true });
  }
  catch { return res.status(503).json({ error: { code: "cleanup_unavailable" } }); }
}
