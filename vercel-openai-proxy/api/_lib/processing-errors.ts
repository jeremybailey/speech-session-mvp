import {TooManyRequestsError, UnauthorizedError, ForbiddenError, BadRequestError,
  ConsumerDiscoveryError, ConsumerRegistryNotConfiguredError} from '@vercel/queue';

export type ProcessingPhase = 'authentication' | 'receipt' | 'capacity' | 'validation'
  | 'submission' | 'publication' | 'cancellation' | 'status';

/** PostgreSQL codes and runtime classes are fixed metadata, not error text. */
export function processingFailureReason(cause: unknown): string {
  const error = cause && typeof cause === 'object'
    ? cause as {code?: unknown; name?: unknown} : {};
  const databaseCodes = ['08000', '08001', '08003', '08006', '08P01', '22001', '22003',
    '22021', '22P02', '22P05', '23502', '23503', '23505', '23514', '25P02', '40001',
    '40P01', '42501', '42601', '42703', '42P01', '53300', '53400', '54000', '57014', '57P01'];
  if (typeof error.code === 'string' && databaseCodes.includes(error.code)) return `postgres_${error.code}`;
  const networkCodes = ['ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND', 'EPIPE'];
  if (typeof error.code === 'string' && networkCodes.includes(error.code)) return error.code;
  if (cause instanceof TypeError) return 'type_error';
  if (cause instanceof RangeError) return 'range_error';
  if (cause instanceof SyntaxError) return 'syntax_error';
  return 'unclassified';
}

/** Only fixed categories leave this boundary. Never log thrown messages, SQL,
 * request bodies, provider responses, tokens, or account identifiers. */
export function processingFailure(cause: unknown, phase: ProcessingPhase) {
  const error = cause && typeof cause === 'object'
    ? cause as {message?: unknown; code?: unknown; status?: unknown} : {};
  const known: Record<string, {code: string; status: number}> = {
    budget_exhausted: {code: 'budget_exhausted', status: 402},
    budget_unavailable: {code: 'budget_unavailable', status: 503},
    database_unavailable: {code: 'database_unavailable', status: 503},
    dedupe_secret_unavailable: {code: 'processing_configuration_unavailable', status: 503},
    model_unavailable: {code: 'processing_configuration_unavailable', status: 503},
    reasoning_unavailable: {code: 'processing_configuration_unavailable', status: 503},
    price_unavailable: {code: 'processing_configuration_unavailable', status: 503},
    fast_experiment_disabled: {code: 'pipeline_unavailable', status: 503},
    invalid_request: {code: 'invalid_request', status: 400},
    invalid_schema: {code: 'invalid_schema', status: 400},
  };
  const selected = typeof error.message === 'string'
    && Object.hasOwn(known, error.message) ? known[error.message] : undefined;
  // Provider/queue authorization failures are service failures, not a request
  // for the patient to sign in again. Keep authentication errors distinct.
  if (phase === 'publication') {
    if (cause instanceof TooManyRequestsError) return {phase, code: 'queue_throttled', status: 429};
    if (cause instanceof UnauthorizedError || cause instanceof ForbiddenError) {
      return {phase, code: 'queue_authorization_unavailable', status: 503};
    }
    if (cause instanceof ConsumerDiscoveryError || cause instanceof ConsumerRegistryNotConfiguredError) {
      return {phase, code: 'queue_consumer_unavailable', status: 503};
    }
    if (cause instanceof BadRequestError) return {phase, code: 'queue_configuration_unavailable', status: 503};
    return {phase, code: 'queue_unavailable', status: 503};
  }
  if (selected) return {phase, ...selected};
  if (['42P01', '42703'].includes(String(error.code))) {
    return {phase, code: 'processing_schema_unavailable', status: 503};
  }
  const status = typeof error.status === 'number' && Number.isInteger(error.status)
    && error.status >= 400 && error.status <= 599 ? error.status : 503;
  return {phase, code: 'processing_unavailable', status};
}
