import { Pool, PoolClient } from "pg";
import { createHmac, randomUUID } from "node:crypto";
import { estimate, pricingVersion, reservation, Usage } from "./pricing";
import { modelIdentity, ProcessingModel } from "./model-policy";

let pool: Pool | undefined;
export function database(): Pool {
  if (!process.env.DATABASE_URL) throw new Error("database_unavailable");
  return pool ??= new Pool({ connectionString: process.env.DATABASE_URL, max: 3,
    connectionTimeoutMillis: 5000, idleTimeoutMillis: 10000, statement_timeout: 10000 });
}
export async function transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await database().connect();
  try { await client.query("BEGIN"); const value = await work(client); await client.query("COMMIT"); return value; }
  catch (error) { await client.query("ROLLBACK"); throw error; }
  finally { client.release(); }
}
export const stages = new Set(["extraction", "classification", "checking", "duplicates",
  "overview_condense", "overview", "condition-synthesis", "condition-context-recovery", "condition-verification"]);
export type WorkloadType='initial'|'incremental'|'retry'|'development'|'unknown';
export function workloadType(value:unknown):WorkloadType {
  return ['initial','incremental','retry','development'].includes(String(value))?value as WorkloadType:'unknown';
}
export type Payload = { stage: string; instructions: string; input: string; response_format: Record<string, unknown>;workload_type?:WorkloadType };
export function validatePayload(value: unknown): Payload {
  const p = value as Payload;
  if (!p || !stages.has(p.stage) || typeof p.instructions !== "string" || typeof p.input !== "string" ||
      !p.response_format || !["json_schema","json_object"].includes(String(p.response_format.type)) ||
      Buffer.byteLength(JSON.stringify(p)) > 200_000) throw new Error("invalid_request");
  const schema = p.response_format.json_schema as Record<string, unknown>;
  if (p.response_format.type === "json_schema" &&
      (!schema || typeof schema.name !== "string" || !schema.schema || schema.strict !== true)) throw new Error("invalid_schema");
  return { stage: p.stage, instructions: p.instructions, input: p.input, response_format: p.response_format,
    ...(p.workload_type?{workload_type:workloadType(p.workload_type)}:{}) };
}
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a],[b]) => a.localeCompare(b))
    .map(([key,val]) => `${JSON.stringify(key)}:${canonical(val)}`).join(",")}}`;
  return JSON.stringify(value);
}
export function requestHash(owner: string, payload: Payload, model: ProcessingModel = 'gpt-4o-mini', effort = 'low'): string {
  const secret = process.env.AI_DEDUPE_SECRET;
  if (!secret) throw new Error("dedupe_secret_unavailable");
  const {workload_type,...clinicalRequest}=payload;
  return createHmac("sha256", secret).update(canonical([owner, "durable-v1", modelIdentity(model, effort), clinicalRequest])).digest("hex");
}
export async function submit(owner: string, payload: Payload) {
  return transaction(db => submitWithinTransaction(db,owner,payload));
}
// Allows a workflow checkpoint and its budgeted step to be committed together.
export async function submitWithinTransaction(db: PoolClient, owner: string, payload: Payload, budgetID = process.env.AI_BUDGET_ID, model: ProcessingModel = 'gpt-4o-mini', effort = 'low') {
  const hash = requestHash(owner, payload, model, effort);
  if (!budgetID) throw new Error("budget_unavailable");
    // Lock global budget before checking dedupe: submissions across all users serialize safely.
    const budget = (await db.query("SELECT * FROM ai_budgets WHERE id=$1 FOR UPDATE", [budgetID])).rows[0];
    if (!budget) throw new Error("budget_unavailable");
    const prior = (await db.query("SELECT id,state FROM ai_jobs WHERE owner=$1 AND request_hash=$2", [owner, hash])).rows[0];
    if (prior) return {...prior,reused:true};
    const reserve = reservation(model, 6000);
    if (BigInt(budget.used_nusd) + BigInt(budget.reserved_nusd) + BigInt(reserve) > BigInt(budget.limit_nusd)) throw new Error("budget_exhausted");
    const id = randomUUID();
    await db.query("UPDATE ai_budgets SET reserved_nusd=reserved_nusd+$2 WHERE id=$1", [budgetID, reserve]);
    await db.query(`INSERT INTO ai_jobs(id,owner,request_hash,stage,model,pricing_version,budget_id,state,reserve_nusd,workload_type,reasoning_effort)
      VALUES($1,$2,$3,$4,$9,$5,$6,'queued',$7,$8,$10)`, [id,owner,hash,payload.stage,pricingVersion,budgetID,reserve,workloadType(payload.workload_type),model,effort]);
    await db.query("INSERT INTO ai_payloads(job_id,payload) VALUES($1,$2)", [id,payload]);
    return { id, state: "queued",reused:false };
}
export async function claim(id?: string) {
  return transaction(async db => {
    const job = (await db.query(`SELECT j.* FROM ai_jobs j JOIN ai_payloads p ON p.job_id=j.id
      WHERE j.state='queued' AND p.expires_at>now() AND ($1::uuid IS NULL OR j.id=$1::uuid)
      ORDER BY j.created_at FOR UPDATE OF j SKIP LOCKED LIMIT 1`,[id ?? null])).rows[0];
    if (!job) return null;
    await db.query("UPDATE ai_jobs SET state='running',started_at=now() WHERE id=$1", [job.id]);
    const payload = (await db.query("SELECT payload FROM ai_payloads WHERE job_id=$1", [job.id])).rows[0].payload;
    return { ...job, payload: payload as Payload };
  });
}
export async function settle(id: string, state: "completed"|"incomplete"|"uncertain", usage?: Usage, output?: string, providerID?: string) {
  await transaction(async db => {
    const job = (await db.query("SELECT * FROM ai_jobs WHERE id=$1 FOR UPDATE", [id])).rows[0];
    if (!job || job.state !== "running") return;
    const cost = estimate(job.model, usage, job.pricing_version);
    // Missing/invalid usage remains an unresolved charge with the full reservation held.
    const finalState = cost === null ? "uncertain" : state;
    if (cost !== null) await db.query(`UPDATE ai_budgets SET reserved_nusd=reserved_nusd-$2,
      used_nusd=used_nusd+$3 WHERE id=$1`, [job.budget_id,job.reserve_nusd,cost]);
    await db.query(`UPDATE ai_jobs SET state=$2,cost_nusd=$3,input_tokens=$4,output_tokens=$5,cached_tokens=$6,
      provider_id=$7,finished_at=now() WHERE id=$1`,
      [id,finalState,cost,usage?.input_tokens ?? null,usage?.output_tokens ?? null,
        usage?.input_tokens_details?.cached_tokens ?? null,providerID ?? null]);
    if (output) await db.query("UPDATE ai_payloads SET result=$2 WHERE job_id=$1 AND expires_at>now()", [id,{output}]);
  });
}
export async function cancel(owner: string, id: string) {
  await transaction(async db => {
    const job = (await db.query("SELECT * FROM ai_jobs WHERE owner=$1 AND id=$2 FOR UPDATE",[owner,id])).rows[0];
    if (!job || job.state !== "queued") return; // An already dispatched request can still incur charges.
    await db.query("UPDATE ai_jobs SET state='cancelled',cost_nusd=0,finished_at=now() WHERE id=$1",[id]);
    await db.query("UPDATE ai_budgets SET reserved_nusd=reserved_nusd-$2 WHERE id=$1",[job.budget_id,job.reserve_nusd]);
    await db.query("DELETE FROM ai_payloads WHERE job_id=$1",[id]);
  });
}
export async function cancelPayload(owner:string,payload:Payload) {
  const job=await transaction(async db=>{
    const budgetID=process.env.AI_BUDGET_ID;
    if(!(await db.query('SELECT id FROM ai_budgets WHERE id=$1 FOR UPDATE',[budgetID])).rows.length) throw new Error('budget_unavailable');
    const hash=requestHash(owner,payload);
    const prior=(await db.query('SELECT id,state FROM ai_jobs WHERE owner=$1 AND request_hash=$2',[owner,hash])).rows[0];
    if(prior) return prior;
    const id=randomUUID();
    await db.query(`INSERT INTO ai_jobs(id,owner,request_hash,stage,model,pricing_version,budget_id,state,reserve_nusd,cost_nusd,finished_at)
      VALUES($1,$2,$3,$4,'gpt-4o-mini',$5,$6,'cancelled',0,0,now())`,[id,owner,hash,payload.stage,pricingVersion,budgetID]);
    return {id,state:'cancelled'};
  });
  await cancel(owner,job.id);
  return (await database().query('SELECT id,state FROM ai_jobs WHERE id=$1 AND owner=$2',[job.id,owner])).rows[0];
}
export async function cleanup() {
  await transaction(async db => {
    // Interrupted workers are NEVER automatically redispatched.
    await db.query("UPDATE ai_jobs SET state='uncertain',finished_at=now() WHERE state='running' AND started_at<now()-interval '5 minutes'");
    const expired = (await db.query(`SELECT j.* FROM ai_jobs j JOIN ai_payloads p ON p.job_id=j.id
      WHERE p.expires_at<=now() AND j.state='queued' FOR UPDATE OF j`)).rows;
    for (const job of expired) {
      await db.query("UPDATE ai_budgets SET reserved_nusd=reserved_nusd-$2 WHERE id=$1",[job.budget_id,job.reserve_nusd]);
      await db.query("UPDATE ai_jobs SET state='expired',finished_at=now() WHERE id=$1",[job.id]);
    }
    await db.query("DELETE FROM ai_payloads WHERE expires_at<=now()");
  });
}
