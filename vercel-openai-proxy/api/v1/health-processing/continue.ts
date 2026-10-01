import type { VercelRequest, VercelResponse } from "@vercel/node";
import { cleanup } from "../../_lib/ledger";
import { runJob } from "../../_lib/worker";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) return res.status(401).end();
  if (req.method !== "GET" && req.method !== "POST") return res.status(405).end();
  try {
    if (process.env.AI_DURABLE_ENABLED !== "true") {
      await cleanup();
      return res.status(200).json({enabled:false});
    }
    return res.status(200).json({processed: await runJob()});
  } catch { return res.status(503).json({error:{code:"worker_unavailable"}}); }
}
