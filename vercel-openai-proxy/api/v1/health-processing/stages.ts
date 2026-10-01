import type { VercelRequest, VercelResponse } from "@vercel/node";
import OpenAI from "openai";
import { verifyKindeBearer } from "../../_lib/verifyKinde";
import { durableEnabledForOwner } from '../../_lib/pilot';

const allowedStages = new Set([
  "extraction", "classification", "checking", "duplicates",
  "overview_condense", "overview", "condition-synthesis", "condition-context-recovery", "condition-verification",
]);
const activeBySubject = new Map<string, number>();
const approvedModels = new Set(["gpt-4o-mini", "gpt-6-luna", "gpt-6-sol", "gpt-6-astra"]);

type StageRequest = {
  stage: string;
  instructions: string;
  input: string;
  response_format: Record<string, unknown>;
  request_id: string;
};

function error(res: VercelResponse, status: number, message: string, code?: string) {
  return res.status(status).json({ error: { message, code } });
}

function responseFormat(value: Record<string, unknown>): Record<string, unknown> {
  if (value.type !== "json_schema") return { type: "json_object" };
  const wrapped = value.json_schema as Record<string, unknown> | undefined;
  if (!wrapped || typeof wrapped.name !== "string" || !wrapped.schema) {
    throw Object.assign(new Error("Invalid response schema"), { status: 400 });
  }
  return {
    type: "json_schema",
    name: wrapped.name,
    strict: wrapped.strict === true,
    schema: wrapped.schema,
  };
}

function policy(stage: string): { model: string; maxOutput: number; reasoning?: "low" } {
  const configured = stage === "condition-synthesis" || stage === "condition-context-recovery" || stage === "condition-verification"
    ? process.env.CLINICAL_CONDITION_MODEL
    : stage === "overview" || stage === "overview_condense"
      ? process.env.CLINICAL_OVERVIEW_MODEL
      : process.env.CLINICAL_ROUTINE_MODEL;
  const model = configured && approvedModels.has(configured) ? configured : undefined;
  if (stage === "condition-synthesis" || stage === "condition-context-recovery" || stage === "condition-verification") {
    return { model: model ?? "gpt-6-astra", maxOutput: 16_000, reasoning: "low" };
  }
  return { model: model ?? "gpt-4o-mini", maxOutput: 6_000,
    ...(model?.startsWith("gpt-6-") ? { reasoning: "low" as const } : {}) };
}

function relayHeader(upstream: Headers, res: VercelResponse, name: string) {
  const value = upstream.get(name);
  if (value) res.setHeader(name, value);
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return error(res, 405, "Method not allowed");

  let subject: string;
  try {
    subject = await verifyKindeBearer(req.headers.authorization);
    if (durableEnabledForOwner(subject)) return error(res, 409, "Use budgeted processing jobs", "durable_endpoint_required");
  } catch (cause: unknown) {
    const value = cause as { status?: number; message?: string };
    return error(res, value.status ?? 401, value.message ?? "Unauthorized");
  }

  const key = process.env.OPENAI_API_KEY?.trim();
  if (!key) return error(res, 500, "OPENAI_API_KEY is missing");
  const body = req.body as Partial<StageRequest> | undefined;
  if (!body || typeof body.stage !== "string" || !allowedStages.has(body.stage) ||
      typeof body.instructions !== "string" || typeof body.input !== "string" ||
      typeof body.request_id !== "string" || !body.response_format) {
    return error(res, 400, "Invalid health-processing stage request");
  }
  if (body.instructions.length > 120_000 || body.input.length > 400_000) {
    return error(res, 413, "Health-processing stage request is too large");
  }

  const active = activeBySubject.get(subject) ?? 0;
  if (active >= 2) {
    res.setHeader("Retry-After", "2");
    return error(res, 429, "Too many concurrent health-processing requests", "client_concurrency_limit");
  }
  activeBySubject.set(subject, active + 1);
  const started = Date.now();
  const selected = policy(body.stage);
  try {
    const client = new OpenAI({ apiKey: key, maxRetries: 0, timeout: 115_000 });
    const request: Record<string, unknown> = {
      model: selected.model,
      store: false,
      max_output_tokens: selected.maxOutput,
      input: [
        { role: "system", content: body.instructions },
        { role: "user", content: body.input },
      ],
      text: { format: responseFormat(body.response_format) },
      metadata: { stage: body.stage, client_request_id: body.request_id },
    };
    if (selected.reasoning) request.reasoning = { effort: selected.reasoning };

    const result = await client.responses.create(request as never, {
      headers: { "X-Client-Request-Id": body.request_id },
    }).withResponse();
    const data = result.data;
    const raw = result.response;
    for (const name of ["retry-after", "x-ratelimit-limit-requests", "x-ratelimit-remaining-requests",
      "x-ratelimit-reset-requests", "x-ratelimit-limit-tokens", "x-ratelimit-remaining-tokens",
      "x-ratelimit-reset-tokens", "x-request-id"]) relayHeader(raw.headers, res, name);
    const usage = data.usage as unknown as {
      input_tokens?: number; output_tokens?: number;
      input_tokens_details?: { cached_tokens?: number };
    } | undefined;
    if (data.status !== "completed" || !data.output_text) {
      console.warn(JSON.stringify({ event: "health_processing_stage", stage: body.stage,
        model: selected.model, ms: Date.now() - started, status: 422,
        requestID: raw.headers.get("x-request-id"), finishReason: data.status }));
      return error(res, 422, "Clinical stage returned incomplete structured output", "clinical_output_incomplete");
    }
    console.info(JSON.stringify({
      event: "health_processing_stage", stage: body.stage, model: selected.model,
      ms: Date.now() - started, status: 200, requestID: raw.headers.get("x-request-id"),
      inputTokens: usage?.input_tokens ?? 0, outputTokens: usage?.output_tokens ?? 0,
      cachedTokens: usage?.input_tokens_details?.cached_tokens ?? 0,
      finishReason: data.status,
      remainingRequests: raw.headers.get("x-ratelimit-remaining-requests"),
      remainingTokens: raw.headers.get("x-ratelimit-remaining-tokens"),
    }));
    return res.status(200).json({
      output: data.output_text,
      model: selected.model,
      request_id: raw.headers.get("x-request-id"),
      usage: {
        input_tokens: usage?.input_tokens ?? 0,
        output_tokens: usage?.output_tokens ?? 0,
        cached_tokens: usage?.input_tokens_details?.cached_tokens ?? 0,
      },
    });
  } catch (cause: unknown) {
    const value = cause as { status?: number; message?: string; code?: string; headers?: Headers };
    const status = value.status ?? 502;
    if (value.headers) {
      for (const name of ["retry-after", "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens", "x-request-id"]) {
        relayHeader(value.headers, res, name);
      }
    }
    console.error(JSON.stringify({ event: "health_processing_stage", stage: body.stage,
      model: selected.model, ms: Date.now() - started, status, code: value.code ?? "unknown" }));
    return error(res, status, value.message ?? "OpenAI request failed", value.code);
  } finally {
    const remaining = (activeBySubject.get(subject) ?? 1) - 1;
    if (remaining <= 0) activeBySubject.delete(subject); else activeBySubject.set(subject, remaining);
  }
}
