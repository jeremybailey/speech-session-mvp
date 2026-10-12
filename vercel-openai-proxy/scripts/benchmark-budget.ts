import type { PoolClient } from 'pg';
// Cumulative $2.25 ceiling approved 2026-10-11 for the fast-details trial; all historical costs still count.
export const experimentLimit = 2_250_000_000n;
export const sharedLimit = 5_000_000_000n;
export function checkExperimentAllowance(committed: bigint, reserve: bigint) {
  if (committed < 0n || reserve <= 0n || committed + reserve > experimentLimit)
    throw Error('experiment_budget_exhausted');
}
/** Caller MUST hold the shared ai_budgets row lock through insertion of the job.
 * Every arm/run uses a distinct owner under this immutable experiment prefix.
 * Missing charges retain their reservation; settled charges replace it. */
export async function assertExperimentAllowance(db: PoolClient, prefix: string, owner: string, reserve: number) {
  if (!/^benchmark-speed-[0-9a-f-]{36}:$/.test(prefix) || !owner.startsWith(prefix)
      || !Number.isSafeInteger(reserve)) throw Error('invalid_experiment_scope');
  const row = (await db.query(`SELECT COALESCE(sum(COALESCE(cost_nusd,reserve_nusd)),0)::text AS committed
    FROM ai_jobs WHERE left(owner,length($1))=$1`,[prefix])).rows[0];
  checkExperimentAllowance(BigInt(row.committed),BigInt(reserve));
}
