import test from 'node:test';
import assert from 'node:assert/strict';
import {processingFailure, processingFailureReason, type ProcessingPhase} from '../api/_lib/processing-errors';
import {TooManyRequestsError, UnauthorizedError, ForbiddenError, BadRequestError,
  ConsumerDiscoveryError, ConsumerRegistryNotConfiguredError} from '@vercel/queue';

test('database diagnostic reasons preserve only allowlisted codes and runtime classes', () => {
  for (const code of ['22P05', '23505', '23514', '42501', '57014']) {
    assert.equal(processingFailureReason({code, message: 'private SQL and source', detail: 'private row'}), `postgres_${code}`);
  }
  assert.equal(processingFailureReason({code: 'ECONNRESET'}), 'ECONNRESET');
  assert.equal(processingFailureReason(new TypeError('private input')), 'type_error');
  assert.equal(processingFailureReason(new RangeError('private input')), 'range_error');
  assert.equal(processingFailureReason(new SyntaxError('private input')), 'syntax_error');
  for (const cause of [null, 'private source', {code: 'private source'}, {code: 'ABCDE'}, {name: 'private source'}]) {
    assert.equal(processingFailureReason(cause), 'unclassified');
  }
});

test('actual queue SDK errors retain rate-limit and configuration categories without leaking messages', () => {
  for (const [cause, code, status] of [
    [new TooManyRequestsError('private response', 60), 'queue_throttled', 429],
    [new UnauthorizedError('private response'), 'queue_authorization_unavailable', 503],
    [new ForbiddenError('private response'), 'queue_authorization_unavailable', 503],
    [new BadRequestError('private response'), 'queue_configuration_unavailable', 503],
    [new ConsumerDiscoveryError('private response'), 'queue_consumer_unavailable', 503],
    [new ConsumerRegistryNotConfiguredError('private response'), 'queue_consumer_unavailable', 503],
  ] as const) {
    assert.deepEqual(processingFailure(cause, 'publication'), {phase: 'publication', code, status});
  }
});

test('budget exhaustion, missing configuration, schema and queue failures are distinct', () => {
  assert.deepEqual(processingFailure(new Error('budget_exhausted'), 'submission'),
    {phase: 'submission', code: 'budget_exhausted', status: 402});
  assert.equal(processingFailure(new Error('budget_unavailable'), 'submission').code, 'budget_unavailable');
  assert.equal(processingFailure(new Error('fast_experiment_disabled'), 'validation').code, 'pipeline_unavailable');
  assert.equal(processingFailure({code: '42703', message: 'private SQL'}, 'submission').code, 'processing_schema_unavailable');
  assert.equal(processingFailure(new Error('invalid_schema'), 'validation').status, 400);
  for (const status of [401, 402, 429, 503]) {
    assert.deepEqual(processingFailure({status, message: 'private queue response'}, 'publication'),
      {phase: 'publication', code: 'queue_unavailable', status: 503});
  }
  assert.equal(processingFailure({status: 401}, 'authentication').status, 401);
});

test('diagnostics never serialize arbitrary error fields or invalid HTTP statuses', () => {
  const phases: ProcessingPhase[] = ['authentication', 'receipt', 'capacity', 'validation',
    'submission', 'publication', 'cancellation', 'status'];
  for (const phase of phases) {
    for (const cause of [null, 'private source', {message: 'private source', code: 'private source',
      status: 'private source', body: 'private source', stack: 'private source'},
      {message: '__proto__', status: 200}, {status: NaN}, {status: 999}]) {
      const result = processingFailure(cause, phase);
      assert.equal(result.status, 503);
      assert.ok(!JSON.stringify(result).includes('private source'));
      assert.deepEqual(Object.keys(result).sort(), ['code', 'phase', 'status']);
    }
  }
});
