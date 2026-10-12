import { reservation } from './pricing';

// Extraction includes both reasoning and the complete structured fact list.
// Keep other stages unchanged; callers cannot select this limit.
export function outputTokenLimit(model: string, stage: string): number {
  return model === 'gpt-6-luna' && stage === 'extraction' ? 10_000 : 6_000;
}

// A worker upgrade must not enlarge requests already queued under a smaller
// reservation. The persisted reservation pins the safe limit for those jobs.
export function reservedOutputTokenLimit(model: string, stage: string, reserved: string | number): number {
  const desired = outputTokenLimit(model, stage);
  if (BigInt(reserved) >= BigInt(reservation(model, desired))) return desired;
  if (BigInt(reserved) >= BigInt(reservation(model, 6_000))) return 6_000;
  throw new Error('insufficient_output_reservation');
}
