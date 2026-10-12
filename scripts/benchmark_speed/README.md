# Isolated reprocessing benchmark

This harness compiles the build-10 record processor, calls its extraction, checking,
contact/symptom reconciliation, condition workflow and overview methods, and saves
and reads back the final overview. It never changes the shipping application's
checker selection. Its private workspace and all clinical input/output belong under
ignored `build/benchmarks/`, not in this directory.

## Reproduce

1. `prepare.py --output <new-private-directory> --archive <decrypted-export> --key <frozen-key.json> --records <five-record-map.json>` verifies source hashes against both the export and key, rejects selected duplicate-marked records, and clears generated state in a private seed.
2. Build the persistence library corresponding to client commit `0e499b6` into `.build/out/Products/Debug`. `compile.py <directory>` compiles that frozen app processor and runs controlled Swift adapter/concurrency tests. Source files under `Sources/` must match that commit; this is checked before compilation.
3. Set the private auth file's `cli` array to the installed official Vercel CLI command. `deploy.py <directory>` creates an expiring, authenticated diagnostic deployment with **no domain assignment** and verifies unchanged pilot aliases. It uses server code from `f7af55e`, with only diagnostic scope/budget/timing changes. Credentials remain server-side.
4. Set `BENCHMARK_REQUEST_HELPER` to the absolute `request.py` path and `BENCHMARK_ARM` to `baseline`, `parallel`, `hybrid`, or `combined`. Run `<directory>/replay <absolute-directory> <arm>-<1..3>`. Each cold run requires a new directory and a separate owner; never delete a partial run to pretend it was fresh.
5. `shadow.py <directory> --run baseline-1` compares identical completed checking payloads through Decisions. It never reads the key and does not apply its results to patient output. Agreement is not clinical accuracy.
   Optional `controls.py <directory>` runs the five synthetic cases emitted by compilation through the exact hybrid prompt. Expected answers stay local. Controlled Swift tests separately cover malformed/refused responses, missing quotes and cancellation.
6. Alternate complete baseline/candidate runs. Run parallel and hybrid independently before combined. Do not advance a candidate after unresolved per-row regressions. Aim for three complete runs per arm, stopping within the authorized experiment budget.
7. Grade each saved record projection using `scripts/score_scorecard.py`, with hash-bound semantic judgments and the frozen key. Store `<record-id>.score.json` in its run directory. Review individual regressions and unsupported additions; do not auto-match clinical content by keywords. Reviewed-only and provisional Draft scoring remain separate.
8. `report.py <directory>` writes timing summaries. Supply `accuracy-review.json` only after explicit per-row/admission/source-preservation review; each approved arm requires `approved: true`. Timing alone never promotes a candidate.
9. `cleanup.py <directory>` snapshots scoped accounting, cancels only undispatched experiment jobs, removes only experiment payloads/checkpoints, verifies zero remaining payloads, removes tracked temporary deployments and local access files. Running jobs must finish before cleanup. Uncertain charges remain reserved. Verify pilot aliases again afterward.

## Interfaces and safeguards

- Default checker is the existing Responses path with one four-assertion batch at a time. Parallel uses two batches; extraction, classification, contact review, grouping and overview are unchanged. The existing ordered, cancellation-aware map is used.
- Hybrid submits only entries with a nonempty quote present verbatim in both the supplied source window and complete original. Each populated required field receives that candidate quote; Decisions must confirm **all** claims, category/attribution, and quote-to-field support. It cannot generate or repair citations.
- The adapter accepts only exact, unique requested IDs and Pass/Fail/Review answers with valid distributions. A Pass requires both confidence and Pass probability >=0.99. This conservative experimental threshold is **not calibrated evidence of correctness**. Refusal, uncertainty, missing quotation, non-Pass or malformed answers fall back to the original checker. No failed/uncertain Decisions verdict directly hides an entry.
- Decisions transport failures retain any unresolved charge and fall back; budget exhaustion stops. Cancellation propagates. In-flight paid requests are never redispatched by the harness.
- The shared budget lock serializes every reservation, including condition child jobs. Under the lock, all owners in the immutable experiment prefix count `COALESCE(cost_nusd,reserve_nusd)` against a cumulative $1 sub-limit. The shared $5 cap is checked independently. No unresolved reservation is discounted.
- Request identities include independent run owners, isolating cold arms. Identical retries within a run remain idempotent. All requests use fixed production model policy; Decisions uses Luna and input-only accounting.
- Output remains the app's existing `SummaryCheck` and stored data formats. Benchmark hooks are applied only to generated local processor source, with exact-match assertions that fail when the frozen source shape changes.

## Measurement limits

Full-run time includes diagnostic transport overhead and all requested phases,
including fallbacks. It is not a phone wall-clock measurement. Stage durations can
overlap; compare independent total elapsed, not summed stage duration. Provider
elapsed is instrumented around Responses calls where present; queue timestamps are
reported separately. Earlier missing instrumentation is missing, not zero. Completed
cold runs and cached retries must never be pooled. Failed runs do not count as fast
completions. Repeated medians, no lost baseline passes, no new unsupported claims or
lost occurrences, and at least 50% less elapsed time are required for release consideration.

The scorecard snapshot contains Draft labels; scores remain provisional until human
adjudication. The key is available only to the separate scoring step, never to either
checker or generation. No deployment to an app domain or TestFlight release occurs
as part of this harness.

## Extraction completion follow-up

`prepare_extraction_replay.py <original-directory> <vercel-cli-command...>` creates
an isolated `extraction-fix/` directory containing the two failed request payloads
and the current output-limit/diagnostic fix. It retains the original experiment
owner prefix, so earlier spending still counts against the same $1 allowance.
It does not rewrite the original baseline. Use `deploy.py` on that directory, then
`extraction_replay.py` to attempt three fresh repetitions per failed payload. Each
completed response must validate against the unchanged structured-output schema.
Stop on any failure. This is completion verification, not a clinical accuracy score
or full-pipeline speed measurement. Run `cleanup.py` afterward on the follow-up
directory, preserving the original evidence and accounting.

For the fresh full comparison, run `prepare_repaired_comparison.py <original-directory>
<complete-frozen-key.json> <vercel-cli-command...>`. This creates a separate
`repaired-comparison/` directory, verifies the tested repair's hashes, requires
positive expectations for every selected record, verifies unchanged source texts,
and versions run owners while retaining the same cumulative experiment budget.
Then compile, deploy, run and clean up that directory as above. `progress.py <run-directory>`
reads local operational progress only, without source text or additional inference.

## Overview completion follow-up

The request-only `OverviewReferenceEncoding` maps durable IDs to short letter codes
and restores returned citations before existing validation/storage. It does not
select evidence, change medical text, or bypass numeric grounding. `compile.py`
recognizes frozen clients containing this repair and compiles its synthetic tests
and an `overview-replay` executable. Run that executable on a private root with
a copied `snapshot/` to test only the overview; never include its timings as full
cold runs. It checks saved/readback output and unchanged source-record bytes.

After three successful isolated overview replays,
`prepare_overview_comparison.py <repaired-comparison-directory>` freezes the same
repair for both full-run arms, using new owners under the original budget prefix.
Its planned first pair is concurrent then serial. Keep all older failed runs and
cleanup all tracked diagnostic deployments and credentials afterward.

`prepare_condition_comparison.py <completion-repaired-comparison-directory>`
carries only the separately tested exact duplicate-heading formatting fix into
a fresh frozen backend. `condition_completion_replay.ts <new-root> <private-plan>
<private-job-response> <batch-index>` reproduces the old rejection offline, checks
all source IDs reach verification, and rejects overlap, conflicting priorities,
unknown references and omissions. It does not make inference calls or accept any
clinical association. Keep this validation distinct from a complete fresh run.

`prepare_downstream_replay.py <all-completion-repairs-directory>` freezes only
the empty-heading formatting fix and a copy of the failed run's saved records.
After offline validation, compile/deploy and run `replay <root> controls-1
--resume-snapshot`. This skips extraction/checking/reconciliation and marks its
report `cold: false`; it cannot qualify as full reprocessing or a speed comparison.
