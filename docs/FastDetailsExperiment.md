# Fast health-details experiment

Branch: `codex/fast-health-details`. This managed worktree includes the uncommitted reliability fixes from the original checkout. The original checkout and current TestFlight deployment remain unchanged.

## Implementation

The opt-in **Fast Health Details** Xcode scheme processes up to three records and four sections per record concurrently, through one fair scheduler with at most four provider requests in flight. The server returns a conservative concurrency ceiling based on the shared and cumulative experiment allowances. Atomic server reservations remain authoritative.

Extraction already returns typed categories, source excerpts and attribution. The experimental adapter adds category definitions and contact/chief-complaint instructions to that same request, removing separate classification and routine contact/complaint extraction calls. Structured lab parsing and its ordering contacts remain available.

Checks contain up to 16 assertions. Every required field still needs independent support. A compact response contains a deduplicated quotation table and field-to-quotation references; decoding expands it into the unchanged SummaryCheck format before the existing admission rules. Non-matching quotations contribute no citations; their affected claims need repair or remain unsupported. Malformed tables, unknown references and duplicate IDs still fail the batch. Candidate quotes are locators, never proof. Negation, uncertainty, medication directions and attribution remain in the checker input.

Each section has one repair round for missing citations and statement-type corrections, bounded to 16 assertions per request. Malformed/truncated check responses split once. Successful halves and split markers persist; a restart does not repeat the failed parent or a completed half. Rejected statements remain source-only, not provisionally verified.

Additive work-unit checkpoints store extraction and check/repair results under the source hash and `fast-details-v1`. Source order determines publication order. Publication retains the original atomic source/edit guards and occurrence reconciliation. The global verification version is unchanged.

Transient network exchanges retry twice using the identical method, URL and body. GET polling never returns to POST submission. Authentication/budget failures close new scheduler admission and stop downstream submission for that run; existing paid requests may finish. Cancellation retains resumable checkpoints.

## Isolation and local build

Open this worktree's `SpeechSessionApp.xcodeproj`, select **Fast Health Details**, and set the scheme environment variable `COLLECTIVECARE_FAST_DETAILS_URL` to a dedicated HTTPS service origin. An empty URL fails before processing; direct API-key fallback is disabled in this scheme. Normal scheme behavior remains available.

The isolated app backend requires `FAST_DETAILS_EXPERIMENT_ENABLED=true` plus the normal Kinde, durable queue and server model configuration. It namespaces authenticated job ownership under the original speed-experiment prefix and enforces the cumulative experiment cap inside the shared budget transaction. Do not enable this flag on the current pilot deployment. The expiring diagnostic endpoint used by the command-line benchmark is separate from this app service configuration.

No app endpoint has been deployed or assigned to the scheme by this experiment. The compiled local build is not a claim of on-device speed; the diagnostic runner is used first to establish processing behavior.

## Validation and benchmark

Offline validation covers evidence tables, missing/invented quotes, rejected attribution, preservation of negation/conditional/medication claims, checkpoint merge, restart, source edits, cancellation, queue bounds, authentication/budget shutdown, one-level splitting and out-of-order publication. Existing verification/recovery suites continue to run. Synthetic model verdicts verify software behavior, not clinical accuracy.

`compile_fast.py` compiles the actual app adapter with the same persistence implementation. `FastMain.swift` supports one long record or all five, fresh and resumed modes, and an explicit concurrency limit. It checks live accounting before inference, saves per-record timings, client queue/operation timings, traces, outputs and ledger receipts locally. `report_fast.py` separates incomplete/resumed results from completed cold timings. Human-key semantic grading remains separate; details-only runs cannot establish condition-link accuracy.

Diagnostic gateway retries are restricted to explicitly identified Vercel protection rejections; they repeat the same request and do not weaken deployment protection. Unknown transport outcomes retain their reservations. Run cleanup after every diagnostic deployment, preserving charges and local evidence.

The user approved a cumulative **$2.25 experiment cap on 2026-10-11**, including every historical charge and unresolved reservation. The shared cap remains $5. Five read-only preflight probes succeeded. The live ledger before the new trial showed $0.9365156 settled and no unresolved experiment reservations. The earlier $0.2145 queued reservation was canceled during scoped cleanup before dispatch.

Historical context: the prior completed five-record run spent 1,230.21 seconds processing records and 1,711.66 seconds for the full flow. This is not a fresh serial baseline. The target is approximately 120 seconds for details; conditions and overview remain separately measured.

Live trial results are saved privately under `build/fast-details-trial`. No speed or accuracy improvement is established until a completed run and output review are recorded.

## First live recovery findings

The first cold long-record attempt failed after 112.5 seconds. Two diagnostic transport defects masked the provider's explicit output-limit reason; the app and runner now classify that reason for bounded splitting, and the runner retrieves full diagnostics after an idempotent submission. A later retry found that rejecting an entire response for one non-verbatim quotation unnecessarily discarded valid checks. Invalid quotations now contribute no evidence at field level, preserving exact-match admission and routing the affected claim to the existing repair pass.

The long record subsequently completed from checkpoints (46 seconds for the final retry, **not a cold timing**). Settled cumulative experiment spending at that point was $0.9911061. This includes historical experiment charges. The initial output review found one retained medication-adherence detail and one unsupported qualifier. Patient-specific review evidence remains in the ignored local report; accuracy equivalence is not established.

## Completed five-record trial

The cold `parallel-2` trial completed all five records: **447.28 seconds** for details (449.54 including budget preflight/report write), versus 1,230.21 historical details seconds. That is approximately **2.75× faster / 63.6% less elapsed time**, not the 10× target. This is one run against historical context, not a fresh paired median. It used 51 jobs, including three successful output-limit split recoveries and ten repair requests, costing $0.1154445. Cumulative experiment spending ended at $1.1065506 of $2.25 with no unresolved reservations.

One sampled expected item improved in visible retention, one unsupported qualifier persisted, and one expected care instruction regressed to source-only because the checker returned nested field identifiers instead of the required parent identifier. No numerical accuracy or equivalence claim is made. Full patient-specific observations and unreviewed-row inventory are private in `build/fast-details-trial/FastReport.md` and `per-row-review.json`.

Remote diagnostic payloads were verified zero, the temporary deployment removed, and pilot aliases unchanged. The iOS build and focused tests pass; configuring a dedicated app-backend URL remains necessary for on-device testing. No TestFlight release was made. Since the details target was missed, downstream full-flow benchmarking is deferred.
