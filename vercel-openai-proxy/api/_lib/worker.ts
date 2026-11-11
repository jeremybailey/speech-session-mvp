import OpenAI from "openai";
import {storyDraftText} from "./story-stream";
import { claim, cleanup, database, settle } from "./ledger";
import { modelOptions } from "./model-policy";
import { reservedOutputTokenLimit } from './output-policy';
import { responseDiagnostics } from './response-diagnostics';

/** Shared by explicit maintenance and durable queue delivery. Only a successful
 * atomic ledger claim can dispatch inference; queue retries are not model retries. */
export class ProviderResponsePending extends Error {}

export async function runJob(id?: string): Promise<number> {
  await cleanup();
  if (process.env.AI_DURABLE_ENABLED !== "true") throw new Error("pilot_disabled");
  if (!process.env.OPENAI_API_KEY && process.env.AI_MOCK_INFERENCE !== "true") throw new Error("credentials_unavailable");
  const job = await claim(id);
  if (!job) {
    if (id) {
      const pending = (await database().query(
        "SELECT j.*, p.payload FROM ai_jobs j JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1 AND j.state='running' AND j.stage IN ('whole-history-generation','whole-history-overview','whole-history-unit-extraction','whole-history-unit-verification') AND j.provider_id IS NOT NULL AND p.expires_at>now()",
        [id]
      )).rows[0];
      if (pending) {
        await collectBackgroundResponse(pending);
        return 1;
      }
    }
    if (id && (await database().query("SELECT state FROM ai_jobs WHERE id=$1", [id])).rows[0]?.state === "running") {
      // Keep delivery alive until another worker settles or cleanup marks the
      // interrupted request uncertain. Never reclaim a dispatched request.
      throw new Error("job_running");
    }
    return 0;
  }
  const conversational = (job.payload.response_format.json_schema as {name?:string})?.name === "story_chat_stream_v1";
  const background = !conversational && ["whole-history-generation","whole-history-overview","whole-history-unit-extraction","whole-history-unit-verification"].includes(job.payload.stage)
    && process.env.AI_WHOLE_HISTORY_PROVIDER_BACKGROUND === "true";
  try {
    if (process.env.AI_MOCK_INFERENCE === "true") {
      await settle(job.id, "incomplete", { input_tokens: 0, output_tokens: 0 });
    } else {
      const schema = job.payload.response_format.json_schema as Record<string, unknown>;
      const client = new OpenAI({ maxRetries: 0, timeout: background ? 15_000 : job.payload.stage === 'whole-history-generation' ? 270_000 : 100_000 });
      const outputLimit = reservedOutputTokenLimit(job.model, job.payload.stage, job.reserve_nusd);
      if (background) {
        await database().query(
          "UPDATE ai_payloads SET payload=payload||'{\"provider_background\":true}'::jsonb WHERE job_id=$1",
          [job.id]
        );
      }
      const providerStarted = performance.now();
      const parameters = { model: job.model, store: false, service_tier: "default",
        ...(background ? { background: true, metadata: { health_job_id: job.id } } : {}),
        max_output_tokens: outputLimit,
        ...modelOptions(job.model, job.reasoning_effort),
        input: [{ role: "system", content: job.payload.instructions }, { role: "user", content: job.payload.input }],
        text: { format: job.payload.response_format.type === "json_schema"
          ? { type: "json_schema", name: schema.name, strict: true, schema: schema.schema }
          : { type: "json_object" } } };
      let result: any;
      if (conversational) {
        const stream = await client.responses.create({...parameters,stream:true} as never) as unknown as AsyncIterable<any>;
        let accumulated="",lastWrite=0;
        for await (const event of stream) {
          if(event.type === "response.created") await database().query("UPDATE ai_jobs SET provider_id=$2 WHERE id=$1 AND state='running'",[job.id,event.response.id]);
          if(event.type === "response.output_text.delta") {
            accumulated+=event.delta;
            const draft=storyDraftText(accumulated);
            if(draft && Date.now()-lastWrite>350) {
              lastWrite=Date.now();
              await database().query("UPDATE ai_payloads SET result=$2 WHERE job_id=$1 AND expires_at>now()",[job.id,{draftText:draft}]);
            }
          }
          if(["response.completed","response.incomplete","response.failed"].includes(event.type)) result=event.response;
        }
        if(!result)throw new Error("stream_interrupted");
        result.output_text=accumulated;
      } else {result=await client.responses.create(parameters as never);}
      if (background) {
        await database().query(
          "UPDATE ai_jobs SET provider_id=$2 WHERE id=$1 AND state='running' AND provider_id IS NULL",
          [job.id, result.id]
        );
        if (result.status === "queued" || result.status === "in_progress") throw new ProviderResponsePending();
      }
      await settle(job.id, result.status === "completed" && result.output_text ? "completed" : "incomplete",
        result.usage ?? undefined, result.output_text, result.id, {...responseDiagnostics(result, outputLimit), providerSeconds: (performance.now() - providerStarted) / 1000});
    }
  } catch (error) {
    if (error instanceof ProviderResponsePending) throw error;
    if (error instanceof OpenAI.APIError && [400,401,403,404,413,422,429].includes(error.status ?? 0)) {
      const outputLimit=reservedOutputTokenLimit(job.model,job.payload.stage,job.reserve_nusd);
      await settle(job.id,"incomplete",{input_tokens:0,output_tokens:0},undefined,undefined,
        {outputTokenLimit:outputLimit,providerStatus:"rejected",providerHTTPStatus:error.status});
      return 1;
    }
    // Once the response ID is durable, retry retrieval or settlement on redelivery.
    if (background) {
      const receipt = (await database().query(
        "SELECT provider_id FROM ai_jobs WHERE id=$1 AND state='running'",
        [job.id]
      )).rows[0];
      if (receipt?.provider_id) throw new ProviderResponsePending();
      // The create call may have reached the provider. Leave the claim in
      // place while the signed webhook can restore the receipt. Cleanup
      // eventually marks an unrecovered submission uncertain.
      throw new Error("provider_receipt_pending");
    } else {
      await settle(job.id, "uncertain");
    }
  }
  return 1;
}


function retrieveBackgroundResponse(id: string) {
  return new OpenAI({ maxRetries: 0, timeout: 15_000 }).responses.retrieve(id);
}

export async function collectBackgroundResponse(job: {
  id: string;
  provider_id: string;
  model: string;
  reserve_nusd: string;
  started_at: Date | string;
  payload: { stage: string };
}, runtime = { retrieve: retrieveBackgroundResponse, settle }) {
  let result;
  try {
    result = await runtime.retrieve(job.provider_id);
  } catch (error) {
    const age = Date.now() - new Date(job.started_at).getTime();
    if (error instanceof OpenAI.NotFoundError && age >= 10 * 60_000) {
      await runtime.settle(job.id, "uncertain");
      return;
    }
    throw new ProviderResponsePending();
  }
  if (result.status === "queued" || result.status === "in_progress") throw new ProviderResponsePending();
  const outputLimit = reservedOutputTokenLimit(job.model, job.payload.stage, job.reserve_nusd);
  try {
    await runtime.settle(
      job.id, result.status === "completed" && result.output_text ? "completed" : "incomplete",
      result.usage ?? undefined, result.output_text, result.id, responseDiagnostics(result, outputLimit)
    );
  } catch {
    // Redelivery retrieves the same response if settlement did not commit.
    throw new ProviderResponsePending();
  }
}
