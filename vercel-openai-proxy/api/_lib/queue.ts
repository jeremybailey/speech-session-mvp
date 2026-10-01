import { QueueClient } from "@vercel/queue";

export const jobQueue = new QueueClient({ region: "iad1" });
export const jobTopic = "health-processing-jobs";

export function queueJobID(message: unknown): string {
  if (!message || typeof message !== "object" || Object.keys(message).length !== 1 ||
      !("id" in message) || typeof message.id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(message.id)) {
    throw new Error("invalid_queue_message");
  }
  return message.id;
}

export async function enqueueJob(id: string): Promise<void> {
  if (process.env.AI_QUEUE_ENABLED !== "true") return;
  queueJobID({ id });
  // No owner, clinical text, filenames, credentials, or source excerpts in queue storage.
  await jobQueue.send(jobTopic, { id }, { retentionSeconds: 7 * 24 * 60 * 60, idempotencyKey: id });
}
