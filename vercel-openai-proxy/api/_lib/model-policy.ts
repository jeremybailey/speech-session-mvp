// Server-owned policy; callers cannot select an arbitrary model or increase output.
export type ProcessingModel = 'gpt-4o-mini' | 'gpt-6-luna';
export function conditionModel(): ProcessingModel {
  const model = process.env.AI_CONDITION_MODEL ?? 'gpt-4o-mini';
  if (model !== 'gpt-4o-mini' && model !== 'gpt-6-luna') throw new Error('model_unavailable');
  return model;
}
export function conditionReasoning(): string {
  const effort = process.env.AI_CONDITION_REASONING ?? 'low';
  if (!['low','medium'].includes(effort)) throw new Error('reasoning_unavailable');
  return effort;
}
export function modelOptions(model: string, effort = 'low') {
  if (!['low','medium'].includes(effort)) throw new Error('reasoning_unavailable');
  if (model === 'gpt-4o-mini') return {};
  if (model === 'gpt-6-luna') return {
    reasoning: { effort },
    // No breakpoints: no cache reads or writes, hence no unaccounted write fees.
    prompt_cache_options: { mode: 'explicit' },
  };
  throw new Error('model_unavailable');
}
export function modelIdentity(model: string, effort = 'low') {
  modelOptions(model, effort); // Fail closed before reserving or dispatching.
  return model === 'gpt-4o-mini' ? model : [model, `${effort}-no-cache-6000-v1`];
}
