import type { VercelRequest, VercelResponse } from "@vercel/node";
import { jobQueue, queueJobID } from "../../_lib/queue";
import { runJob } from "../../_lib/worker";

// Security boundary: the queue/v2beta trigger makes this a private Vercel
// consumer, not a public HTTP API. Keep the trigger in vercel.json.
const consume = jobQueue.handleNodeCallback(async (message: unknown) => {
  try {
    const id=queueJobID(message);
    const processed=await runJob(id);
    console.info("ai_queue_step",JSON.stringify({id,processed}));
  }
  catch { throw new Error("job_delivery_deferred"); } // SDK logs must not expose database/provider error details.
}, { visibilityTimeoutSeconds: 300, retry: () => ({ afterSeconds: 60 }) });

export default async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader("Cache-Control", "no-store");
  // Log only switches, before SDK consumption, to distinguish routing failures
  // from a disabled worker. Never log the request, payload, or environment values.
  console.info("ai_queue_delivery", JSON.stringify({
    queueEnabled: process.env.AI_QUEUE_ENABLED === "true",
    durableEnabled: process.env.AI_DURABLE_ENABLED === "true",
    mock: process.env.AI_MOCK_INFERENCE === "true"
  }));
  if (process.env.AI_QUEUE_ENABLED !== "true" || process.env.AI_DURABLE_ENABLED !== "true") return res.status(503).end();
  return consume(req, res);
}
