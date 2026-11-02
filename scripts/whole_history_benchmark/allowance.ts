import type { PoolClient } from 'pg';
const config=require('../api/config.json');
export const experimentLimit=5_000_000_000n;
export function checkAllowance(committed:bigint,reserve:bigint){
 if(committed<0n||reserve<=0n||committed+reserve>experimentLimit)throw Error('experiment_budget_exhausted');
}
/** Invoked after idempotency lookup, while shared budget row remains locked.
 * Scope all child stages, retain unknown charges at their reservation amount. */
export async function enforceWholeHistoryAllowance(db:PoolClient,owner:string,reserve:number){
 if(!/^benchmark-whole-history-[0-9a-f-]{36}:$/.test(config.prefix)||!owner.startsWith(config.prefix+(config.runVersion??''))||!Number.isSafeInteger(reserve))throw Error('invalid_experiment_scope');
 if(Date.now()>config.expiresAt)throw Error('experiment_expired');
 const r=(await db.query(`SELECT COALESCE(sum(COALESCE(cost_nusd,reserve_nusd)),0)::text AS committed FROM ai_jobs WHERE left(owner,length($1))=$1`,[config.prefix])).rows[0];
 checkAllowance(BigInt(r.committed),BigInt(reserve));
}
