import type { VercelRequest, VercelResponse } from "@vercel/node";
import { jobQueue, jobTopic, queueJobID } from "../../_lib/queue";
import {runWholeHistory} from '../../_lib/whole-history-background';
import { ProviderResponsePending, runJob } from "../../_lib/worker";

// Security boundary: the queue/v2beta trigger makes this a private Vercel
// consumer, not a public HTTP API. Keep the trigger in vercel.json.
const consume = jobQueue.handleNodeCallback(async (message: unknown) => {
  const id = queueJobID(message);
  try {
    if (await runWholeHistory(id)) return;
    const processed = await runJob(id);
    console.info("ai_queue_step", JSON.stringify({ id, processed }));
  } catch (error) {
    if (error instanceof ProviderResponsePending) {
      // Each poll has its own delivery budget. A slow response must not exhaust
      // the original message's retry count simply by remaining in progress.
      const slot = Math.floor(Date.now() / 5_000) + 1;
      try {
        await jobQueue.send(jobTopic, { id }, {
          delaySeconds: 5,
          idempotencyKey: `${id}:provider-poll:${slot}`
        });
        return;
      } catch {
        throw new Error("provider_poll_enqueue_failed");
      }
    }
    throw new Error("job_delivery_deferred");
  }
}, { visibilityTimeoutSeconds: 360, retry: () => ({ afterSeconds: 60 }) });

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
