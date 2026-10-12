/** Only bounded operational metadata: never persist provider error text or source content. */
export type ResponseDiagnostics = {
  providerStatus?: string;
  providerSeconds?: number;
  incompleteReason?: 'max_output_tokens' | 'content_filter' | 'other';
  outputTokenLimit: number;
  reasoningTokens?: number;
};
export function responseDiagnostics(response: unknown, outputTokenLimit: number): ResponseDiagnostics {
  const r = response as {status?: unknown; incomplete_details?: {reason?: unknown};
    usage?: {output_tokens_details?: {reasoning_tokens?: unknown}}} | null;
  const metadata: ResponseDiagnostics = {outputTokenLimit};
  if (typeof r?.status === 'string' && ['completed','incomplete','failed','cancelled','queued','in_progress'].includes(r.status))
    metadata.providerStatus = r.status;
  const reason = r?.incomplete_details?.reason;
  if (reason != null) metadata.incompleteReason = reason === 'max_output_tokens' || reason === 'content_filter' ? reason : 'other';
  const tokens = r?.usage?.output_tokens_details?.reasoning_tokens;
  if (typeof tokens === 'number' && Number.isSafeInteger(tokens) && tokens >= 0) metadata.reasoningTokens = tokens;
  return metadata;
}
