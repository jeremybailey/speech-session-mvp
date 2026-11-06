import type { VercelRequest, VercelResponse } from "@vercel/node";
import OpenAI from "openai";
import { resumeRecordJob } from "./incremental-workflow";
import { database } from "./ledger";
import { runWholeHistory } from "./whole-history-background";

async function readEvent(req: VercelRequest): Promise<string> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const bytes = Buffer.from(chunk);
    size += bytes.length;
    if (size > 64 * 1024) throw new Error("event_too_large");
    chunks.push(bytes);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") return res.status(405).end();
  const secret = process.env.OPENAI_WHOLE_HISTORY_WEBHOOK_SECRET;
  if (!secret || !process.env.OPENAI_API_KEY) return res.status(503).end();
  const client = new OpenAI({ webhookSecret: secret, maxRetries: 0, timeout: 10_000 });
  const headers = new Headers();
  for (const name of ["webhook-id", "webhook-timestamp", "webhook-signature"]) {
    const value = req.headers[name];
    if (typeof value === "string") headers.set(name, value);
  }
  let event;
  try {
    event = await client.webhooks.unwrap(await readEvent(req), headers);
  } catch {
    return res.status(400).end();
  }
  if (event.type !== "response.completed" && event.type !== "response.incomplete"
      && event.type !== "response.failed" && event.type !== "response.cancelled") return res.status(204).end();
  try {
    const response = await client.responses.retrieve(event.data.id);
    const id = response.metadata?.health_job_id;
    if (!id || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
      return res.status(204).end();
    }
    // Only our marked job, with an unsettled reservation, may adopt a missed
    // receipt. A settled job is safe to revisit for overview handoff recovery.
    const db = database();
    await db.query(
      `UPDATE ai_jobs j SET provider_id=$2,state='running',finished_at=NULL
        FROM ai_payloads p WHERE j.id=$1 AND p.job_id=j.id AND p.expires_at>now()
        AND p.payload->>'provider_background'='true' AND j.stage IN ('whole-history-generation','whole-history-overview','whole-history-unit-extraction','whole-history-unit-verification')
        AND j.state IN ('running','uncertain') AND j.cost_nusd IS NULL
        AND (j.provider_id IS NULL OR j.provider_id=$2)`,
      [id, response.id]
    );
    const matched = (await db.query(
      "SELECT 1 FROM ai_jobs WHERE id=$1 AND stage IN ('whole-history-generation','whole-history-overview','whole-history-unit-extraction','whole-history-unit-verification') AND provider_id=$2",
      [id, response.id]
    )).rows.length;
    if (matched) {
      const incremental = process.env.AI_INCREMENTAL_RECORDS_ENABLED === "true" && await resumeRecordJob(id);
      if (!incremental) await runWholeHistory(id);
    }
    return res.status(204).end();
  } catch {
    // Return a retryable response without emitting clinical or provider payloads.
    return res.status(503).end();
  }
}
