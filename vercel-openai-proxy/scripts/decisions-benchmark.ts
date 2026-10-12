// Offline diagnostic only: no production route imports this module.
// https://developers.openai.com/api/docs/guides/decisions (2026-10-09)
import { createHmac, randomUUID } from 'node:crypto';
import { assertExperimentAllowance, sharedLimit } from './benchmark-budget';
import { database, transaction } from '../api/_lib/ledger';

export const decisionsPricingVersion = 'decisions-2026-10-09-v1';
// Full model context at the long-context rate, independent of a token estimate.
export const decisionsReservation = 1_050_000 * 200;
type Question = { type: 'choice'; name: string; instructions: string;
  choices: { value: string; description: string }[] };
export type Request = { model: 'gpt-6-luna'; input: string; questions: Question[] };
export function validateDecisionRequest(value: unknown): Request {
  const p = value as Request;
  if (!p || p.model !== 'gpt-6-luna' || typeof p.input !== 'string' || !p.input.trim()
      || !Array.isArray(p.questions) || !p.questions.length || p.questions.length > 32
      || Buffer.byteLength(JSON.stringify(p)) > 50_000) throw Error('invalid_decision_request');
  const names = new Set<string>();
  for (const q of p.questions) {
    if (q.type !== 'choice' || typeof q.name !== 'string' || !q.name || names.has(q.name)
        || typeof q.instructions !== 'string' || !q.instructions.trim()
        || !Array.isArray(q.choices) || q.choices.length !== 3
        || q.choices.some(c => typeof c.description !== 'string' || !c.description.trim())
        || [...q.choices.map(c => c.value)].sort().join(',') !== 'Fail,Pass,Review') throw Error('invalid_decision_request');
    names.add(q.name);
  }
  // Drop unrecognised top-level options: fixed model, region-neutral endpoint.
  return { model: p.model, input: p.input, questions: p.questions.map(q => ({
    type: 'choice', name: q.name, instructions: q.instructions,
    choices: q.choices.map(c => ({ value: c.value, description: c.description })) })) };
}
export function validDecisionAnswers(result: any, payload: Request): boolean {
  return result?.model === payload.model && Array.isArray(result.answers)
    && result.answers.length === payload.questions.length
    && result.answers.every((a: any, i: number) => {
      if (a?.name !== payload.questions[i].name) return false;
      if (a.type === 'refusal') return true;
      if (a.type !== 'choice' || !['Pass','Fail','Review'].includes(a.choice)
          || !Number.isFinite(a.confidence) || a.confidence < 0 || a.confidence > 1
          || !Array.isArray(a.probabilities) || a.probabilities.length !== 3) return false;
      const values = a.probabilities.map((p: any) => p?.value);
      return [...values].sort().join(',') === 'Fail,Pass,Review'
        && a.probabilities.every((p: any) => Number.isFinite(p.probability) && p.probability >= 0 && p.probability <= 1)
        && Math.abs(a.probabilities.reduce((n: number,p: any)=>n+p.probability,0)-1) < 0.001;
    });
}
export function decisionCost(usage: unknown): number | null {
  const u = usage as { input_tokens?: number; output_tokens?: number } | undefined;
  const input = u?.input_tokens;
  if (!Number.isSafeInteger(input) || input! < 0 || input! > 1_050_000 || u?.output_tokens !== 0) return null;
  // Decisions charges input only; cached tokens do not reduce this rate.
  return input! * (input! > 272_000 ? 200 : 100);
}
export async function runDecisionBenchmark(owner: string, value: unknown, experimentPrefix?: string) {
  const payload = validateDecisionRequest(value);
  if (!owner.startsWith('benchmark-') || process.env.AI_DURABLE_ENABLED !== 'true'
      || process.env.AI_MOCK_INFERENCE === 'true' || !process.env.OPENAI_API_KEY
      || !process.env.AI_DEDUPE_SECRET || !process.env.AI_BUDGET_ID) throw Error('decision_benchmark_unavailable');
  const budgetID = process.env.AI_BUDGET_ID;
  const hash = createHmac('sha256', process.env.AI_DEDUPE_SECRET)
    .update(JSON.stringify([decisionsPricingVersion, owner, payload])).digest('hex');
  const reservation = await transaction(async db => {
    const budget = (await db.query('SELECT * FROM ai_budgets WHERE id=$1 FOR UPDATE', [budgetID])).rows[0];
    if (!budget || BigInt(budget.limit_nusd) > (experimentPrefix ? sharedLimit : 1_000_000_000n)) throw Error('budget_configuration_changed');
    const prior = (await db.query('SELECT id,state FROM ai_jobs WHERE owner=$1 AND request_hash=$2', [owner, hash])).rows[0];
    if (prior) return { ...prior, reused: true };
    if (experimentPrefix) await assertExperimentAllowance(db,experimentPrefix,owner,decisionsReservation);
    if (!experimentPrefix && Number((await db.query('SELECT count(*) FROM ai_jobs WHERE owner=$1 AND pricing_version=$2',
        [owner, decisionsPricingVersion])).rows[0].count) >= 12) throw Error('benchmark_request_limit');
    if (BigInt(budget.used_nusd) + BigInt(budget.reserved_nusd) + BigInt(decisionsReservation) > BigInt(budget.limit_nusd)) throw Error('budget_exhausted');
    const id = randomUUID();
    await db.query('UPDATE ai_budgets SET reserved_nusd=reserved_nusd+$2 WHERE id=$1', [budgetID, decisionsReservation]);
    // Insert already running in the same transaction: the Responses worker must never claim this request.
    await db.query(`INSERT INTO ai_jobs(id,owner,request_hash,stage,model,pricing_version,budget_id,state,reserve_nusd,workload_type,reasoning_effort,started_at)
      VALUES($1,$2,$3,'checking','gpt-6-luna',$4,$5,'running',$6,'development','low',now())`,
      [id, owner, hash, decisionsPricingVersion, budgetID, decisionsReservation]);
    await db.query('INSERT INTO ai_payloads(job_id,payload) VALUES($1,$2)', [id, payload]);
    return { id, state: 'running', reused: false };
  });
  if (!reservation.reused) {
    let result: any, providerID: string | null = null, httpStatus: number | null = null;
    try {
      const response = await fetch('https://api.openai.com/v1/decisions', { method: 'POST',
        headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload), signal: AbortSignal.timeout(100_000) });
      providerID = response.headers.get('x-request-id'); httpStatus = response.status;
      if (response.ok) result = await response.json();
      // Do not log error bodies, source text or credentials; never retry automatically.
    } catch { /* An unknown outcome retains the entire reservation. */ }
    const cost = decisionCost(result?.usage);
    await transaction(async db => {
      const job = (await db.query('SELECT * FROM ai_jobs WHERE id=$1 FOR UPDATE', [reservation.id])).rows[0];
      if (!job || job.state !== 'running') return;
      const validAnswers = validDecisionAnswers(result,payload);
      const state = cost === null ? 'uncertain' : validAnswers ? 'completed' : 'incomplete';
      if (cost !== null) await db.query('UPDATE ai_budgets SET reserved_nusd=reserved_nusd-$2,used_nusd=used_nusd+$3 WHERE id=$1',
        [job.budget_id, job.reserve_nusd, cost]);
      await db.query(`UPDATE ai_jobs SET state=$2,cost_nusd=$3,input_tokens=$4,output_tokens=$5,provider_id=$6,finished_at=now() WHERE id=$1`,
        [job.id, state, cost, result?.usage?.input_tokens ?? null, result?.usage?.output_tokens ?? null, providerID]);
      await db.query('UPDATE ai_payloads SET result=$2 WHERE job_id=$1 AND expires_at>now()',
        [job.id, { decision: result ?? null, httpStatus }]);
    });
  }
  return (await database().query(`SELECT j.id,j.state,j.cost_nusd,j.reserve_nusd,j.input_tokens,j.output_tokens,j.created_at,j.started_at,j.finished_at,
    CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END result
    FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1 AND j.owner=$2`, [reservation.id, owner])).rows[0];
}
