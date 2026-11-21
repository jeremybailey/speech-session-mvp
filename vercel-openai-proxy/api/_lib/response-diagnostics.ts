/** Only bounded operational metadata: never persist provider error text or source content. */
export type ResponseDiagnostics = {
  providerStatus?: string;
  providerSeconds?: number;
  providerLifecycleSeconds?: number;
  collectionDelaySeconds?: number;
  providerHTTPStatus?: number;
  incompleteReason?: 'max_output_tokens' | 'content_filter' | 'other';
  outputTokenLimit: number;
  reasoningTokens?: number;
};
export function responseDiagnostics(response: unknown, outputTokenLimit: number, nowSeconds = Date.now() / 1000): ResponseDiagnostics {
  const r = response as {created_at?: unknown; completed_at?: unknown; status?: unknown; incomplete_details?: {reason?: unknown};
    usage?: {output_tokens_details?: {reasoning_tokens?: unknown}}} | null;
  const metadata: ResponseDiagnostics = {outputTokenLimit};
  if (typeof r?.status === 'string' && ['completed','incomplete','failed','cancelled','queued','in_progress'].includes(r.status))
    metadata.providerStatus = r.status;
  const reason = r?.incomplete_details?.reason;
  if (reason != null) metadata.incompleteReason = reason === 'max_output_tokens' || reason === 'content_filter' ? reason : 'other';
  const tokens = r?.usage?.output_tokens_details?.reasoning_tokens;
  if (typeof tokens === 'number' && Number.isSafeInteger(tokens) && tokens >= 0) metadata.reasoningTokens = tokens;
  // Background POST duration measures submission, not generation. Provider times
  // separate its queue + generation from our result collection delay.
  const created=r?.created_at,completed=r?.completed_at;
  if(r?.status==='completed' && typeof created==='number' && typeof completed==='number'
    && Number.isSafeInteger(created) && Number.isSafeInteger(completed) && created>0
    && completed>=created && completed-created<=604800) {
    metadata.providerLifecycleSeconds=completed-created;
    const delay=nowSeconds-completed;
    if(Number.isFinite(delay)&&delay>=0&&delay<=604800)metadata.collectionDelaySeconds=Math.round(delay*1000)/1000;
  }
  return metadata;
}
