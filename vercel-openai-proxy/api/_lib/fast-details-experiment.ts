import { createHash } from 'node:crypto';
import type { PoolClient } from 'pg';
import { assertExperimentAllowance, experimentLimit } from '../../scripts/benchmark-budget';

// Immutable: all earlier speed experiments and unresolved charges remain included.
export const speedExperimentPrefix = 'benchmark-speed-ae5743a8-51fd-4ba2-9a80-a26a06357715:';
export function fastDetailsEnabled() { return process.env.FAST_DETAILS_EXPERIMENT_ENABLED === 'true'; }
export function processingOwner(subject: string): string {
  return fastDetailsEnabled() ? speedExperimentPrefix + 'fast-details-app:' + createHash('sha256').update(subject).digest('hex') : subject;
}
export function fastDetailsCapacity(remaining: bigint, reservation: bigint): number {
  if (remaining <= 0n || reservation <= 0n) return 0;
  return Number(remaining / reservation > 4n ? 4n : remaining / reservation);
}
export async function enforceFastDetailsBudget(db: PoolClient, owner: string, reserve: number) {
  if (!owner.startsWith(speedExperimentPrefix + 'fast-details-app:')) return;
  if (!fastDetailsEnabled()) throw new Error('fast_experiment_disabled');
  try { await assertExperimentAllowance(db, speedExperimentPrefix, owner, reserve); }
  catch (error) {
    if ((error as Error).message === 'experiment_budget_exhausted') throw new Error('budget_exhausted');
    throw error;
  }
}
export async function readFastDetailsCapacity(db: PoolClient, budgetID: string, reserve: number) {
  const budget = (await db.query('SELECT limit_nusd::text,used_nusd::text,reserved_nusd::text FROM ai_budgets WHERE id=$1', [budgetID])).rows[0];
  if (!budget) throw new Error('budget_unavailable');
  const row = (await db.query(`SELECT COALESCE(sum(COALESCE(cost_nusd,reserve_nusd)),0)::text AS committed
    FROM ai_jobs WHERE left(owner,length($1))=$1`, [speedExperimentPrefix])).rows[0];
  const shared = BigInt(budget.limit_nusd) - BigInt(budget.used_nusd) - BigInt(budget.reserved_nusd);
  const experiment = experimentLimit - BigInt(row.committed);
  const remaining = shared < experiment ? shared : experiment;
  return { pipeline: 'fast-details-v1', maxInFlight: fastDetailsCapacity(remaining, BigInt(reserve)),
    remaining_nusd: String(remaining > 0n ? remaining : 0n), reservation_nusd: String(reserve) };
}
