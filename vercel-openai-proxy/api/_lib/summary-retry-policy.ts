/** Only explicit, revision-checked retry calls use this policy. Never automatic. */
export function mayReplaceUnconfirmedStep(row: {job_state:string;provider_id?:string|null;attempt:number;started_at?:Date|string|null}, now=Date.now()):boolean {
 const started=row.started_at ? new Date(row.started_at).getTime() : NaN;
 return row.job_state==='uncertain' && !row.provider_id && row.attempt===0
  && Number.isFinite(started) && now-started>=10*60_000;
}
