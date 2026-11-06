import test from "node:test";
import assert from "node:assert/strict";
import { collectBackgroundResponse, ProviderResponsePending } from "../api/_lib/worker";

test("redelivery retrieves the same background response after interruption and settlement failure", async () => {
  const job = {
    id: "local-job", provider_id: "resp_test", model: "gpt-6-luna",
    reserve_nusd: "1000000000", started_at: new Date(), payload: { stage: "whole-history-generation" }
  };
  const retrieved: string[] = [];
  const settled: string[] = [];
  let settlementAttempts = 0;
  const runtime: NonNullable<Parameters<typeof collectBackgroundResponse>[1]> = {
    async retrieve(id) {
      retrieved.push(id);
      if (retrieved.length === 1) throw new Error("interrupted connection");
      return {
        id, status: retrieved.length === 2 ? "in_progress" : "completed",
        output_text: "synthetic output", output: [],
        usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }
      } as Awaited<ReturnType<NonNullable<Parameters<typeof collectBackgroundResponse>[1]>["retrieve"]>>;
    },
    async settle(id, state) {
      if (++settlementAttempts === 1) throw new Error("database temporarily unavailable");
      settled.push(id + ":" + state);
    }
  };
  for (let attempt = 0; attempt < 3; attempt++) {
    await assert.rejects(collectBackgroundResponse(job, runtime), ProviderResponsePending);
  }
  await collectBackgroundResponse(job, runtime);
  assert.deepEqual(retrieved, Array(4).fill("resp_test"));
  assert.deepEqual(settled, ["local-job:completed"]);
});
