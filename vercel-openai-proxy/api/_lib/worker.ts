import OpenAI from "openai";
import { claim, cleanup, database, settle } from "./ledger";
import { modelOptions } from "./model-policy";

/** Shared by explicit maintenance and durable queue delivery. Only a successful
 * atomic ledger claim can dispatch inference; queue retries are not model retries. */
export async function runJob(id?: string): Promise<number> {
  await cleanup();
  if (process.env.AI_DURABLE_ENABLED !== "true") throw new Error("pilot_disabled");
  if (!process.env.OPENAI_API_KEY && process.env.AI_MOCK_INFERENCE !== "true") throw new Error("credentials_unavailable");
  const job = await claim(id);
  if (!job) {
    if (id && (await database().query("SELECT state FROM ai_jobs WHERE id=$1", [id])).rows[0]?.state === "running") {
      // Keep delivery alive until another worker settles or cleanup marks the
      // interrupted request uncertain. Never reclaim a dispatched request.
      throw new Error("job_running");
    }
    return 0;
  }
  try {
    if (process.env.AI_MOCK_INFERENCE === "true") {
      await settle(job.id, "incomplete", { input_tokens: 0, output_tokens: 0 });
    } else {
      const schema = job.payload.response_format.json_schema as Record<string, unknown>;
      const client = new OpenAI({ maxRetries: 0, timeout: 100_000 });
      const result = await client.responses.create({ model: job.model, store: false, service_tier: "default", max_output_tokens: 6000,
        ...modelOptions(job.model, job.reasoning_effort),
        input: [{ role: "system", content: job.payload.instructions }, { role: "user", content: job.payload.input }],
        text: { format: job.payload.response_format.type === "json_schema"
          ? { type: "json_schema", name: schema.name, strict: true, schema: schema.schema }
          : { type: "json_object" } } } as never);
      await settle(job.id, result.status === "completed" && result.output_text ? "completed" : "incomplete",
        result.usage ?? undefined, result.output_text, result.id);
    }
  } catch {
    await settle(job.id, "uncertain");
  }
  return 1;
}
