// USD per million tokens. Unknown models fail closed; never guess a price.
// https://developers.openai.com/api/docs/models/gpt-4o-mini (2026-09-29)
export const pricingVersion = "2026-09-30-v2";
const prices: Record<string, { input: number; cached: number; output: number }> = {
  "gpt-4o-mini": { input: 0.15, cached: 0.075, output: 0.60 },
  // https://developers.openai.com/api/docs/models/gpt-6-luna (2026-09-30)
  // Luna requests explicitly disable cache writes in model-policy.ts.
  "gpt-6-luna": { input: 0.10, cached: 0.01, output: 0.50 },
};
export type Usage = { input_tokens?: number; output_tokens?: number;
  input_tokens_details?: { cached_tokens?: number } };
export function estimate(model: string, usage?: Usage, version = pricingVersion): number | null {
  if (![pricingVersion,"2026-09-29-v1"].includes(version) || (version === "2026-09-29-v1" && model !== "gpt-4o-mini")) throw new Error("price_unavailable");
  const price = prices[model];
  if (!price) throw new Error("price_unavailable");
  const input = usage?.input_tokens, output = usage?.output_tokens;
  const cached = usage?.input_tokens_details?.cached_tokens ?? 0;
  if (input === undefined || output === undefined ||
      ![input, output, cached].every(x => Number.isSafeInteger(x) && x >= 0) || cached > input) return null;
  // Integer nano-USD avoids floating point errors when adding ledger entries.
  const long = model === "gpt-6-luna" && input > 272_000;
  const cost = ((input - cached) * Math.round(price.input * 1000) + cached * Math.round(price.cached * 1000)) * (long ? 2 : 1)
    + output * Math.round(price.output * 1000) * (long ? 1.5 : 1);
  return Number.isSafeInteger(cost) ? cost : null;
}
export function reservation(model: string, output: number): number {
  // Reserve the entire supported input context, not a character/token heuristic.
  return estimate(model, { input_tokens: model === "gpt-6-luna" ? 1_050_000 : 128_000, output_tokens: output })!;
}
