/** Server-selected and persisted at submission; retries keep their original policy. */
export function newSummaryExecutionPolicy(kind: string): string {
  if(kind !== 'practitioner')return 'baseline-three-v1';
  if(process.env.AI_SUMMARY_PARALLEL_V2 !== 'true')return 'baseline-three-v2';
  return process.env.AI_SUMMARY_MERGE_LOW === 'true' ? 'parallel-six-low-merge-v2' : 'parallel-six-v2';
}
export function summaryConcurrency(policy: unknown): number {
  return typeof policy==='string' && ['parallel-six-v1','parallel-six-low-merge-v1','parallel-six-v2','parallel-six-low-merge-v2'].includes(policy) ? 6 : 3;
}
export function summaryReasoning(policy:unknown,step:{phase:string;key:string}):'low'|'medium' {
  // Only consolidation BEFORE original-source audits is eligible. Final merges,
  // extraction, checks, audits and publication retain medium reasoning.
  return ['parallel-six-low-merge-v1','parallel-six-low-merge-v2'].includes(String(policy)) && step.phase==='merge' && step.key.startsWith('merge:') ? 'low':'medium';
}

export function knownSummaryExecutionPolicy(policy:unknown):boolean {
 return typeof policy==='string' && ['baseline-three-v1','baseline-three-v2','parallel-six-v1','parallel-six-low-merge-v1','parallel-six-v2','parallel-six-low-merge-v2'].includes(policy);
}
