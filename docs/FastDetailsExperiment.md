# Fast health-details experiment

Branch: `codex/fast-health-details`. This managed worktree includes the uncommitted reliability fixes from the original checkout. The original checkout and current TestFlight deployment remain unchanged.

## Implementation

The opt-in **Fast Health Details** Xcode scheme processes up to three records and four sections per record concurrently, through one fair scheduler with at most four provider requests in flight. The server returns a conservative concurrency ceiling based on the shared and cumulative experiment allowances. Atomic server reservations remain authoritative.

Extraction already returns typed categories, source excerpts and attribution. The experimental adapter adds category definitions and contact/chief-complaint instructions to that same request, removing separate classification and routine contact/complaint extraction calls. Structured lab parsing and its ordering contacts remain available.

Checks contain up to 16 assertions. Every required field still needs independent support. A compact response contains a deduplicated quotation table and field-to-quotation references; decoding expands it into the unchanged SummaryCheck format before the existing admission rules. Non-matching quotations contribute no citations; their affected claims need repair or remain unsupported. Malformed tables, unknown references and duplicate IDs still fail the batch. Candidate quotes are locators, never proof. Negation, uncertainty, medication directions and attribution remain in the checker input.

Each section has one repair round for missing citations and statement-type corrections, bounded to 16 assertions per request. Malformed/truncated check responses split once. Successful halves and split markers persist; a restart does not repeat the failed parent or a completed half. Rejected statements remain source-only, not provisionally verified.

Additive work-unit checkpoints store extraction and check/repair results under the source hash and `fast-details-v1`. Source order determines publication order. Publication retains the original atomic source/edit guards and occurrence reconciliation. The global verification version is unchanged.

Transient network exchanges retry twice using the identical method, URL and body. GET polling never returns to POST submission. Authentication/budget failures close new scheduler admission and stop downstream submission for that run; existing paid requests may finish. Cancellation retains resumable checkpoints.

## Local build on the shared backend

The fast pipeline is now integrated into the usual `CascadeProjects/SpeechSessionMVP` checkout. Select **Fast Health Details** and run on the phone while signed in. This scheme enables `COLLECTIVECARE_FAST_DETAILS=1`; no alternate URL or duplicate backend is needed. The ordinary scheme and existing TestFlight builds retain their current processing flow.

The transport marks submissions, polling, cancellation, uploads and usage requests with `X-CollectiveCare-Pipeline: fast-details`. After normal Kinde authentication, the server scopes only those requests to the existing experiment namespace and cumulative $2.25 allowance, inside the shared $5 cap. Unmarked requests preserve their original owner identity. Model settings and atomic reservation accounting are unchanged. The marker selects accounting, never grants authentication or a larger budget.

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


## V2: reusable checked facts

`fast-details-v2.1` (the refined v2 candidate) keeps the existing OpenAI models, reasoning settings, four-request scheduler, budget ledger and patient-data formats. Ordinary sources up to 24,000 characters use one extraction unit; larger sources split at nearby text boundaries. Structured-report parsing remains unchanged. Malformed or truncated extraction units split once, with split markers and successful children checkpointed independently.

The checker references the request's locally validated quotation table directly. Its response evidence table contains only additional quotations. Citation object keys are fixed to that entry's required fields, and each value is a list of evidence references, and decoding independently rejects unknown fields and duplicate/colliding evidence IDs. Quotation matching and the semantic admission gate remain mandatory. Checks still contain up to 16 assertions, with one bounded split and one repair round.

Completed same-source, same-version facts are reused from the live store without republishing over patient edits. Presentation projections can regroup these facts without extraction or source checking. This preserves the Granola-inspired separation between source processing and presentation; it does not claim Granola performs equivalent clinical verification. Conditions and overview retain their existing behavior, and newly generated factual claims retain their existing checks.

V2 diagnostic evidence is stored privately in `build/fast-details-v2-trial`. The saved-assertion `check` mode replays the actual compact checker against unchanged drafts and original source context, retains split recovery checkpoints, and is distinct from a cold full-record run. No benchmark key is included in model inputs. The compiler uses the current Swift package build layout. Diagnostic preparation explicitly disables shared maintenance in the temporary worker.

The first v2 long-record trial completed in 346.17 seconds with two output-limit checker splits. Inspection showed repeated citation-object keys and redundant decision IDs consumed output capacity. V2.1 changes citations to a fixed-field object of evidence-reference lists, restores IDs locally from decision keys, and requests explanations only for unsupported/uncertain decisions. Model settings and the 6,000-token check limit stay unchanged. Initial v2 traces and source hashes remain separate from the refined candidate.


## V2.1 measured result

The refined candidate completed all five records in **181.33 seconds**, versus **446.09 seconds** for a fresh frozen-v1 run with identical data/key and unchanged model settings/concurrency: **2.46× faster, 59.4% less elapsed time**. Requests fell from 48 to 21; actual model cost fell from $0.1124688 to $0.0522598. V1 required two output-limit split recoveries; v2.1 required none. This is one cold run per configuration, candidate then baseline, not a repeated median. The roughly 163-second target was missed. Downstream consolidation, conditions and overview remain unmeasured.

The Granola-inspired reuse path was measured locally across five completed records: approximately 0.00183 seconds, zero provider requests, unchanged stored bytes. This is reuse, not cold-processing latency. Presentation changes consume checked facts without restarting extraction.

Accuracy is mixed and completeness regressed in several reviewed rows. All 89 candidate expectations received a provisional visible-details review: 50 Pass, 22 Partial, 15 Fail, two Ambiguous. These are not full-row clinical scores; the Draft key needs human adjudication and downstream dimensions were not scored. Selected fresh-pair comparisons identify ten retention/qualifier regressions and six visibility improvements. Do not infer clinical equivalence from speed or entry counts. Private row references and findings are in `build/fast-details-v2-trial/FastReport.md` and `per-row-review.json`.

Validation: 42 focused Swift tests, 89 existing recovery/downstream tests, 12 Python harness tests and seven budget/isolation tests passed. The experimental iOS simulator build passed. Final cumulative spending was $1.3211059 of $2.25, with no unresolved experiment reservations. Remote diagnostic payloads were verified zero, both temporary deployments removed, local access files removed, and pilot aliases unchanged. No release was made.

## Shared-backend integration, October 11

The v2.1 implementation and earlier uncommitted fixes were integrated into the normal checkout with a backup of pre-integration working files. The historical sections above describe the earlier isolated experiments; an isolated app endpoint is no longer required. Fast processing remains opt-in pending accuracy follow-up. No TestFlight build is automatically released.

Shared backend deployment `dpl_2RWbYh3MadmKvCfUD1LuAkciqWAu` was promoted and the app alias `speech-session-mvp.vercel.app` verified on October 11. Read-only production readiness passed; unauthenticated fast requests returned 401 both before and after promotion. Validation: 40 backend tests passed (two existing integration tests skipped), 42 focused Swift tests passed, transport tests passed, and the Fast Health Details simulator build succeeded. No model inference or patient upload was performed during deployment validation. Phone reprocessing remains the user's next test.

## Reservation pressure during phone testing

The authenticated ledger inspection after the phone run showed $3.3545143 shared settled spending and $0.0684 shared reserved, within the $5 cap. The experiment rows totaled $1.46157375 settled with no unresolved experiment reservations; the phone owner accounted for $0.14046785 (128 jobs). These are a live ledger snapshot, not a cold benchmark. Startup concurrency could admit four requests but cease to fit four conservative reservations as actual spending accumulated. The scheduler previously stopped the entire run on any 402.

The local fix marks only non-workflow POST submission rejections as reservation backpressure. With other operations active, it reduces concurrency, releases the rejected permit, and requeues the same operation. A rejection when alone still stops; polling failures, authentication and unknown-charge results are not retried this way. No cap or backend change was made. Nineteen fast-pipeline tests, transport checks and the simulator build pass. Rebuild Fast Health Details and retry unfinished work to validate on the phone.

## Fast-details-v2.2: structured PDFs and grouped contacts

The opt-in Fast Health Details scheme now batches compatible structured report units up to 12,000 characters / 16 rows instead of 2,500 characters / three rows. Complete rows and inherited headings stay together; different sections stay separate. Ordinary transcripts and clinical source verification retain their existing behavior. A separate v2.2 checkpoint identity prevents old segmentation from substituting for this trial.

At the end of detail processing, source-backed contact identity review evaluates up to 16 candidate groups together with a strict complete-partition response. Two independent partitions must agree on every combination; their intersection preserves disagreements without transitive merging. Oversized inputs split before inference; missing context leaves contacts separate. Successful merges are followed by another bounded round to join matching groups spanning initial batches. Source/revision/exclusion and saved-preference guards remain in place; source occurrences are never removed. Decisions are cached by original request content. The ordinary processing scheme retains the earlier pairwise reviewer.

Offline structural measurement: 48 short compatible medication rows become three extraction units instead of 16 (81.25% fewer units). Ten equivalent contact groups require two review calls in the synthetic fixture, replacing pairwise review. These are request-structure measurements, not elapsed-time or clinical-accuracy results. No paid model run or cap change was made for this implementation. A completed cold run on the large PDF is still required before reporting a measured speedup. Field-selective repair and broader verification reuse were not changed in this trial, to isolate batching and contact-review effects.

### October 12 phone-run contact response fix

The first grouped contact job completed at the provider in 1.05 seconds but returned `{"groups":[[0,1],[0]]}` for two candidate groups. The app correctly rejected repeated membership; the array schema failed to prevent it. The v2 contract instead requires one integer identity-label property for every contact, with no extra properties and an enumerated label range. Independent partitions are still intersected before any merge. Both the request schema and local review cache identity are versioned so retry cannot reuse the malformed v1 result. Extraction/checking checkpoints remain unchanged. Ten offline contact-review tests pass, including the observed malformed output, complete assignment schema, reviewer disagreement, source changes, edit/exclusion protection, and occurrence preservation. No additional model inference was performed for diagnosis or validation.

## October 12 fresh v2.2 comparison and condition timing

A fresh cold pair on the same frozen five records completed in 233.95 seconds for v2.1 and 254.27 seconds for v2.2: the candidate was 8.7% slower in this single pair, with 21 rather than 22 requests and costs of $0.0590583 versus $0.0613518. Both completed five records and recovered one output-limit checker failure. This dataset does not exercise the large structured PDF or repeated-contact workload targeted by v2.2; it does not establish a causal performance regression or improvement.

Using one consistent provisional visible-retention rubric across 89 expectations, baseline scored 41 Pass / 31 Partial / 14 Fail / 3 Ambiguous, versus candidate 39 / 29 / 18 / 3. Pass-only scores are 41/86 versus 39/86; partials count zero and ambiguous labels are excluded. These are not full-row clinical accuracy scores. Condition links, body-system placement and an exhaustive unsupported-assertion audit remain unscored. The draft key and judgments need human adjudication. Several supported facts were hidden after unsupported optional metadata failed verification; targeted metadata correction should preserve the supported core without weakening evidence checks.

A separate replay from candidate saved details took 361.54 seconds to organize conditions, with 14 mapping and 14 independent verification requests, costing $0.0359325. Provider execution accounted for 254.25 seconds; diagnostic transport, queueing and local work account for the remainder, so this is not phone latency. Contact and symptom reconciliation made no provider requests in this sample. All source occurrences and transcripts were preserved. Overview was not run.

Exact repeated source windows account for 66.9% of source-window text bytes. Offline lossless packing with one evidence table per request reduced 14 batches to nine under the same 24KB/30-entry limits. This is the next proposed condition experiment, not an implemented or measured model speedup. Independent membership verification and source/edit protections remain required.

Private report and row-level evidence: `build/fast-details-v22-comparison/Comparison.md`. Eight budget/isolation tests and the Python isolation test passed; both current Swift diagnostic harnesses compiled. Cumulative experiment spending ended at $1.72060835 of the approved $2.75, with no unresolved experiment reservations. Remote diagnostic payloads were verified zero, both temporary deployments and local access files removed, and production aliases unchanged. The $5 shared cap remains unchanged; the diagnostic cap change was not deployed to the shared app backend. No app release was made.

## October 12 synthesis efficiency research

The fresh condition trace points to sequential round trips and repeated evidence, not a need for a new provider. Keep OpenAI, Swift and TypeScript. The next experiment should be evidence compaction followed by smaller output contracts and incremental reuse, measured separately.

Published evidence and its limits:

- [OpenAI latency guidance](https://developers.openai.com/api/docs/guides/latency-optimization) prioritizes reducing generated tokens, request count and avoidable sequential dependencies. Its input-token reduction heuristic predicts modest latency benefits alone. For our pipeline, evidence compaction matters mainly because it permits fewer batches; a 66.9% reduction in repeated evidence bytes does not imply a 66.9% speedup.
- [Granola enhanced notes](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes) describes transcript, raw-note and calendar inputs, source inspection and changing templates after a meeting. These are documented product behaviors, not disclosure of a reusable clinically checked fact-store architecture. Our adaptation is to make templates consume persisted checked facts, preserving provenance and verifying new claims.
- [Heidi Verify](https://support.heidihealth.com/en/articles/14698472-heidi-verify) documents a separate post-generation clinical-entity review against transcript/context, background progress and discrepancy/omission review. It reports typically under two minutes for that analysis. This is not an apples-to-apples benchmark against our multi-record processing and is not proof of error-free synthesis. The useful pattern is separating generation from scoped verification with explicit status.
- [LlamaIndex TreeSummarize implementation](https://developers.llamaindex.ai/python/framework-api-reference/response_synthesizers/tree_summarize/) publicly implements repacking chunks, asynchronous chunk synthesis and recursive reduction. It is an open implementation rather than a clinical app. Borrow efficient packing and bounded parallel work; do not replace original clinical evidence with recursively compressed prose that can lose negation or qualifiers.
- [LangChain context engineering](https://www.langchain.com/blog/context-engineering-for-agents) organizes context handling into persistence, selection, compression and isolation. For us, selection must retain the exact supporting source and attribution; similarity alone cannot decide clinical links.

Recommended experiments, in order:

1. Encode exact source windows once per condition request, with request-local references from each entry, and pack after compaction under the same caps. Preserve original occurrence IDs, source text, deterministic ordering, durable workflow recovery and independent membership checks. Offline sizing was 14 to nine mapping batches; live savings remain unknown.
2. Make condition checking return compact heading/entry IDs and verdicts, with explanations only for rejected or uncertain links. Restore names and metadata locally from the request. Validate complete, unique coverage. Keep the independent check; avoid asking it to regenerate already-known facts and titles.
3. Cache supported fact-to-condition associations by source/fact revisions, condition meaning, patient edits and verifier contract. Presentation-only changes need no clinical calls. New or changed claims and relationships do. Repair unsupported optional metadata at field level instead of hiding a supported core fact.
4. Profile actual device upload/poll/queue time. The approximately 107 seconds outside provider execution in the diagnostic condition run includes CLI transport and cannot all be attributed to the phone. Reuse durable jobs after polling failures.
5. Only after those comparisons, test parallel mapping against one frozen condition catalogue, then global reconciliation and independent verification. Current batches depend on prior accepted groups, so simply running them in parallel changes semantics and risks duplicates.

No new keyword clinical matching, model change or Decisions dependency is needed. This research does not claim a new measured improvement. The deployment accompanying it contains the current validated backend fixes; these proposed condition optimizations are not yet implemented.

### Deployment of validated backend fixes

On October 12, production deployment `dpl_MKPPKjZY8XcLUwwfjvGx2NJxKKXR` was built with the read-only production readiness gate, then promoted to `speech-session-mvp.vercel.app`. Rollback reference: `dpl_2RWbYh3MadmKvCfUD1LuAkciqWAu`. Local typecheck and 40 backend tests passed; two database integration tests were skipped. Production readiness verified authentication configuration, existing migrations, unchanged model policy and the shared budget. No inference or database migration was performed. The approved cumulative experiment cap is now $2.75 on the shared backend as well; historical charges remain included and the shared $5 ceiling is unchanged. No new TestFlight binary was released. The initial submission used the wrong root layout and failed before promotion; the successful submission contained only the backend under the configured repository root.

## Compact condition experiment, October 12

Implemented additive, opt-in `table-v1` condition evidence and `condition_compact_verdict_v1` checker responses. Source windows share exact string storage but source occurrences remain distinct. Batch packing uses compact size under existing limits; original saved plans and result formats remain compatible. The isolated diagnostic configuration alone enabled the candidate; it was not deployed to the shared app.

A fresh saved-details pair (candidate then baseline) completed condition organization in 345.85s baseline versus 321.70s candidate: 7.0% faster, 20.8% cheaper ($0.0358629 vs $0.0284143), 32 vs 20 requests, zero technical completion failures. Provider execution was 248.14s vs 252.85s. All 87 occurrences and the identical session contents survived. This is one pair with diagnostic transport overhead, not repeated medians or phone end-to-end latency. The two-minute target was missed.

Quality was mixed. Provisional heading presence was 12/18 vs 13/18, heading/body-system agreement 9/18 vs 10/18, and all four prohibited diagnoses remained absent. These do not establish full-row accuracy. Unassigned occurrences increased from ten to fifteen; meaningful assignment regressions remain. The candidate is not approved for release. Private per-entry changes and key review are under `build/condition-compact-v1/Report.md`.

Reasoning accounted for 86.3% of candidate output tokens; shortening the visible response did not reduce total generation. The next proposed comparison should isolate condition-stage reasoning effort while preserving independent source verification, and resolve recovery of standalone concerns after rejected associations. No model or reasoning setting changed in this experiment.

Typecheck and 43 backend tests passed (two database integration tests skipped). Temporary payloads were verified zero, diagnostic deployment/access files removed, and production aliases unchanged. Cumulative spending is $1.78488555 of the $2.75 experiment cap, with no unresolved experiment charges. No production or TestFlight release was made.

## Condition reasoning and rejected-link recovery, October 12

Three isolated runs used the same 87 checked facts. Against the earlier compact medium/medium reference of 321.70s, low mapping alone took 307.03s (4.6% faster), low checking alone 265.30s (17.5% faster), and low both plus rejected-link recovery 396.11s (23.1% slower). Requests were 20, 20 and 27; costs $0.0211489, $0.0254758 and $0.0226921. Each completed without technical failure and preserved all occurrences. This is one run per arm against a historical same-day reference, includes variable diagnostic transport overhead, and excludes extraction and overview. It does not establish phone end-to-end speed or repeated medians.

Added opt-in recovery for rejected members of otherwise supported groups. Existing accepted links stay fixed, each recovery unit is attempted once, and alternatives still require independent verification. The combined trace recovered three entries using nine recovery calls. Offline replay matched final memberships and preserved prior accepted links. Unflagged behavior and shared production reasoning policy remain unchanged.

Accuracy remains mixed: lower mapping left more facts unassigned; low checking improved a missing heading but retained classification/qualifier concerns. The combined run recovered useful standalone concerns but retained missing headings and body-system mismatches. No full-row clinical equivalence or release qualification is claimed. The next targeted experiment should reduce recovery round trips and validate low checking with medium mapping; no new model dependency is needed.

Typecheck and 45 tests passed; two database integration tests were skipped. Private timing, quality notes and per-entry changes are in `build/condition-reasoning-v1/Report.md`. This round cost $0.0693168; cumulative experiment spending is $1.85420235 of $2.75 with no unresolved experiment charges. Cleanup verified zero scoped remote payloads, removed the temporary deployment/access files and confirmed production aliases unchanged. No production or TestFlight release was made.

## Packed recovery and build 11 candidate, October 12

Packed recovery preserves per-entry rejection rules while combining work across source batches under existing size/count limits. Both new trials used two recovery calls instead of the prior nine-call combined-recovery example, although model effort and generated proposals differ, so this is not a controlled nine-to-two latency comparison. All 87 occurrences survived; offline replay matched final results and retained accepted links.

Medium mapping/low checking finished in 264.29s, 20 requests, $0.0254966; medium/medium finished in 303.36s, 20 requests, $0.0259861. Recovery added three entries and one entry respectively. Unassigned counts were 12 and 20. Historical references were 265.30s and 321.70s. These are one-off saved-details condition trials, not cold whole-flow timings or accuracy-equivalent speedups. Missing headings and body-system disagreements remain. The candidate keeps compact/packed condition recovery and lower reasoning opt-in; existing medium condition behavior remains the default.

Build 11 consolidates checked-fact processing, final consolidation, checkpoints, network recovery, output-limit handling and existing presentation fixes. The ordinary app scheme now enables fast-details-v2.2 without a launch variable and uses the normal shared pilot allowance. Explicit Fast Health Details development runs retain their experiment namespace and cumulative sub-limit. Neither allowance is raised. The released pipeline contract is accepted without an experiment flag; unknown future versions remain gated. Existing saved summaries are not invalidated.

Private comparison: `build/condition-recovery-rc/Report.md`. The earlier v2.2 details comparison remains mixed (39/86 provisional visible-retention passes versus 41/86 for v2.1); no new full-row accuracy or 10× claim is made. This is an evaluation release candidate for review, not automatic TestFlight distribution.

Cleanup verified zero scoped remote payloads and removed the diagnostic deployment/access files. Production aliases were unchanged during the experiment. Cumulative experiment spending is $1.90568505 of $2.75, with no unresolved experiment charges. Shared budget remains $5; unrelated reservations were not released.

Release-candidate backend `dpl_Dfc8jpBG8XXngiQzC1rTJRYNGUrN` passed the read-only production readiness gate and was promoted after diagnostic cleanup. It accepts the known checked-facts contract and reports normal shared-budget capacity for the ordinary app; experimental owners remain separately capped. Existing clients retain their original condition plans, and the candidate still sends `condition-exact-heading-v2`, so packed condition recovery stays off. Models remain Luna medium. Rollback backend: `dpl_MKPPKjZY8XcLUwwfjvGx2NJxKKXR`.

Final build-11 Release archive succeeded. Both production aliases were verified on the candidate backend and unauthenticated processing returned 401. Validation: 364 Swift tests (two skips), 50 backend tests (two database integration skips), 15 offline regression scripts, and current benchmark-adapter compilation passed. No TestFlight upload/distribution was performed.

## Build 11 TestFlight distribution, October 12

After Jeremy authorized release following his local test, the signed build 1.0993 (11), app commit `d0fde1e`, was uploaded successfully. Apple processing and unchanged standard-encryption/no-France compliance are complete. The existing five-person internal CollectiveCare Founders group has access, and What to Test is saved. No model policy, condition experiment flags or spending caps were changed during distribution. Jeremy reported under-one-minute local processing; possible checkpoint reuse means this is not a cold benchmark or a new accuracy result.
