# OpenAI proxy (Vercel)

Validates **Kinde** access tokens, then forwards requests to `api.openai.com`.

Deploy this folder as a Vercel project. See [docs/KindeAndVercelSetup.md](../docs/KindeAndVercelSetup.md) for environment variables.

**Do not enable request-body logging** for these routes in production analytics.

## Durable processing foundation — not pilot-ready

This is an opt-in foundation, not completion of the 10× rollout. The app pilot
remains off. Existing production routes remain unchanged while the durable flag
is off; the new controls do not retroactively protect that deployment.

### Preview verification — 2026-09-30

- Existing project: `speech-session-mvp`; Neon `neon-charcoal-lens` and the five
  new AI settings are Preview-only. Existing OpenAI/Kinde settings are unchanged.
- Mock Preview: https://speech-session-hnfcccbom-jeremy-baileys-projects.vercel.app
  (`dpl_BSXQHV4aiv5cuju3xg4xWuZD9UKZ`). Vercel authentication remains enabled.
- Protected Preview build applied the database migration and exercised the actual
  ledger/worker implementation against Neon under Node 24. Synthetic tests passed
  for concurrent submission/claim, persisted output, completed-result reuse,
  interrupted requests with retained reservations, quota exhaustion, cancellation,
  owner isolation, usage totals and temporary-payload expiration.
- Live HTTP tests: jobs, usage and continuation reject missing credentials with
  401; legacy stages/chat/audio return 409 in durable mode. Successful Kinde-authenticated
  app-to-HTTP processing and Settings rendering still need end-to-end verification.
- This deployment overrides durable/mock flags to true and overrides the OpenAI
  key to empty. No paid inference was made. Test accounting uses separate synthetic
  budgets; the shared real evaluation limit remains $1, unspent.
- Production deployment remained `dpl_Hqkf3kEggWgzhkjAHt8cfj5dqFpu` before and after.
- No scheduler was provisioned: Vercel Cron runs only on Production, not Preview.
  Manual worker tests do not establish unattended execution or seven-day retention
  guarantees. Only synthetic data is allowed until scheduling is implemented.

`npm run vercel-build` runs type checking and an opt-in migration/smoke script.
Database changes require all of `VERCEL_ENV=preview`, `AI_PREVIEW_VERIFY=true`,
`AI_MOCK_INFERENCE=true`, and `AI_DURABLE_ENABLED=true`. The script refuses an
unexpected database, removes the OpenAI key from its process and blocks OpenAI HTTP.
Never use this smoke script to migrate a database containing real user jobs.

Implemented:

- PostgreSQL migration `migrations/001_ai_ledger.sql`: owner-scoped stage jobs,
  temporary payload/results, persistent nonclinical usage, shared $1 evaluation budget.
- Authenticated `POST/GET/DELETE /api/v1/health-processing/jobs`; stable server-side
  HMAC deduplication, atomic claims, completed-result reuse, queued cancellation.
- `GET /api/v1/health-processing/usage?timezone=America/New_York`: ledger-only,
  owner-scoped totals, entries, shared budgets. No inference calls.
- Cron-secret-protected `GET/POST /api/v1/health-processing/continue`: one bounded
  stage per invocation; stale running work becomes uncertain, never redispatched.
- Conservative full-context reservations, integer nano-USD accounting, versioned
  gpt-4o-mini prices. Missing prices fail closed; missing usage retains reservations.
- Seven-day clinical input/output expiry; cleanup deletes expired payloads and retains
  usage rows. The daily production cleanup schedule can lag expiry, so a strict
  seven-day physical-deletion SLA still needs validation. Never log bodies.
- Settings totals/details/report and a gated submit/poll transport; no fallback from
  this transport to unbudgeted inference. Source verification remains in the app.
- Review/visibility changes do not invalidate condition mapping. Exact legacy
  accepted caches and interrupted checkpoints remain reusable during migration.
- Gated incremental app mapping preserves unaffected groups/manual choices; edits
  or deletions conservatively recheck their dependent group. One combined contextual
  mapping pass plus independent changed-link verification uses request-local IDs.
  Stable condition UUIDs survive one-to-one name changes; splits/merges get new IDs.
- `AI_QUEUE_ENABLED=true` publishes opaque job IDs to a private `queue/v2beta`
  consumer in `iad1`. Atomic targeted claims prevent redelivery from repeating
  inference. The flag is off by default. `cleanup` has a separate daily production
  cron and can run while inference is disabled.

Before enabling even a mock deployment:

1. Select and provision managed PostgreSQL with appropriate clinical-data controls,
   TLS and private server credentials. Apply the migration using an authorized
   server role. RLS is enabled without client policies; never expose this role.
   Verify backup retention also satisfies the clinical retention policy.
2. Set `DATABASE_URL`, a stable random `AI_DEDUPE_SECRET`, `AI_BUDGET_ID=evaluation-v1`,
   `CRON_SECRET`, `AI_DURABLE_ENABLED=true`, `AI_MOCK_INFERENCE=true`, and existing
   Kinde settings. Do not rotate the dedupe secret without a migration strategy.
3. Verify queued delivery with `AI_QUEUE_ENABLED=true` in mock-only Preview first.
   Publish synthetic smoke jobs through the ready deployment's runtime, never its
   build. Build-time queue-test flags are rejected. Runtime `ai_queue_step` logs
   and the ledger's terminal state must prove actual delivery;
   successful publishing alone is insufficient. Keep the queue trigger configured:
   Vercel provides consumer isolation, not application-level HTTP authentication.
   Verify the daily `cleanup` cron in Production and add failure/retention alerts.
4. Deploy and verify owner isolation, reservations, cancellation, expiry and usage
   with mocked inference. Mock output intentionally cannot be used clinically.

The app build-time Info.plist Boolean `DurableAIProcessingEnabled` selects the new
transport. Do NOT enable it for testers yet. When server durable mode is on, legacy
chat/stage endpoints are blocked, and cloud audio is explicitly disabled pending
budgeted audio integration. On-device transcription is unaffected.

Remaining implementation/acceptance gates:

- Whole-import server orchestration: condition mapping/verification now continues
  off-phone; extraction/import sequencing remains app-owned.
- Workload types (initial/incremental/retry/development), remaining per-stage record
  counts, and attribution when multiple parents reuse a previously charged child.
- Incremental extraction cache and one controlled escalation. The new incremental
  mapping policy is implemented behind the pilot flag but still needs clinical
  model evaluation; deterministic tests do not establish clinical quality.
- Budgeted transcription (currently blocked in durable mode) and model-comparison
  pricing/routing. Only gpt-4o-mini has a verified price in the new ledger.
- Clinical quality acceptance through the new production-prompt/schema harness.
  The old direct paid evaluation path remains disabled because it bypasses the ledger.
- Full UI tests and persistent per-account usage cache; current stale figures are
  held only for the lifetime of the Settings view. Latest-job totals now include
  condition parent jobs; unavailable standalone-stage record counts remain explicit.
- Attributable historical billing reconstruction. No billing export was supplied;
  the reported $10 is not enough to establish a controlled 10× comparison.
- Successful authenticated end-to-end app verification, the shared ≤$1 paid evaluation, quality acceptance,
  measured cost comparison, and only then the two-person pilot distribution.

Do not claim verified savings from pricing alone. Recurring database/scheduler
charges are separate from API costs and have not been quoted or incurred here.

### Offline checks

Use Node 22.12+ (the deployment requirement), `npm run typecheck`, and `npm test`.
For real transaction tests, set `AI_TEST_DATABASE_URL` to a **new empty disposable
local database**; tests refuse any database with existing public tables. The suite
applies the migration and covers concurrent deduplication/claims, budget exhaustion,
uncertain outcomes, interruption, cancellation, expiry, owner isolation, timezone
boundaries, rolling windows, and usage projections excluding clinical content.
No API key is required. Without the test URL, database tests are explicitly skipped.

Local validation on 2026-09-29: PostgreSQL tests passed; TypeScript checks passed;
31 condition/schema focused Swift tests passed; Simulator app built. The protected
Preview build subsequently passed type checking and cloud-database smoke tests
under deployment Node 24 on 2026-09-30.

Additional app-side checks on 2026-09-30: 33 focused condition/schema tests passed.
The Organize action and processor now reuse unchanged accepted results. Completed
exact requests are cached independently of the history fingerprint for seven days;
their keys include stage, model, route, schema, instructions, and input and are stored
as SHA-256 digests. Expired entries are pruned on cache access. Unrelated history
changes can reuse identical requests. Subsequent incremental work passed the full
Swift suite: 261 tests, one skipped, no failures. The simulator app built. Four
backend tests, including real disposable PostgreSQL concurrency and mocked queue
redelivery/interruption, passed with no model requests. TypeScript checks passed.
These results do not establish a measured 10× saving. Production and the installed
phone app have not been updated with these changes.

Vercel documents Queues on all plans with 1,000,000 included Hobby operations;
function compute remains separately metered. No plan upgrade was requested or made.
See https://vercel.com/docs/queues/pricing and https://vercel.com/docs/queues/concepts.

### Queue deployment verification (2026-09-30)

Mock-only Preview `dpl_D1nyBa255EG9dghTkY6JxxnoaPAA` deployed successfully at
https://speech-session-5m8izshst-jeremy-baileys-projects.vercel.app with an empty
OpenAI key. Cloud type checks and database smoke checks passed. The private queue
consumer returned 404 to public requests as expected. However, queue execution is
**not verified**: runtime logs showed no invocations, and synthetic job
`ed298097-55c7-40ad-8497-1a7c5da93476` remained queued after targeted redelivery.
The diagnostic follow-up build `dpl_5xqJ8QhQTwzx4LFqYF9bv51v1rsk` intentionally
failed its delivery assertion. Do not enable this path for clinical data or promote
either Preview to Production. Signed-in dashboard diagnostics confirmed 9 published
messages and zero received messages/consumer activity. A local Vercel build confirms
the generated queue function contains the expected private trigger, consumer name,
and 120-second duration; deployment and publisher both use `iad1`.

Diagnostic Preview `dpl_2KF8yCT9k45KKj2tasKZ5BgjQFBm` adds nonclinical delivery-switch
logs before SDK consumption and delays build-time synthetic messages by 120 seconds
to allow consumer registration to finish. Its OpenAI key is empty and inference is
mocked. Publication logs include only opaque job/deployment/message IDs. Delivery is
still an explicit rollout gate. Queue retries are capped at 20 deliveries; exhausted
delivery does not reset or redispatch the paid ledger claim.

The follow-up ledger check `dpl_GS5eu44CNFgwPJJyfrLLAB7jxwhk` also failed:
job `cf980468-cddf-49fd-94a7-aa8d0ad601e6` remained `queued` after the delay and
another explicit delivery to the ready deployment. No worker-entry diagnostic
appeared. Project API confirms Fluid compute is enabled and function region is
`iad1`. Thus neither build-time visibility delay nor disabled Fluid compute explains
the failure. Push-consumer registration/delivery remains unresolved; do not treat
the queue as operational or substitute client polling as background continuation.

No paid inference was run. This work has not changed Production or the phone; a
separate Production redeployment was visible in the dashboard and was left alone.

### Runtime queue verification — passed (2026-09-30)

This supersedes the unresolved push-delivery conclusion above. A no-database/no-AI
Preview `dpl_CCsFtykwts3UupkCUEY1P97dygtW` published and consumed the same synthetic
message in under one second. The SDK's Node callback is a `QueueClient` method,
not a top-level named export. The production worker already uses the correct method.

The real mock worker then passed in `dpl_CBjG7C1W5Kg9JVgn3AYg2KeekhhL`:
- Runtime publication at 13:17:36 EDT; `ai_queue_step` logged `processed:1` at 13:17:37.
- Synthetic job `cf980468-cddf-49fd-94a7-aa8d0ad601e6` transitioned from `queued`
  to `incomplete` (the intentional mock terminal state), with `cost_nusd:"0"`.
- Repeating the identical runtime submission retained that same terminal job and $0 cost.
- OpenAI key was empty and mock inference explicitly enabled. No paid evaluation ran.

Build-time publication, including explicit deployment targeting and delayed messages,
was not a valid delivery test in this environment. Its exact platform-level cause is
not established. The build smoke script no longer publishes queue messages and rejects
its obsolete queue-test flags. It claims only its own synthetic job.

The temporary `/api/queue-smoke` route exists only in the diagnostic staging checkout
and that protected Preview, not in application source. It is gated to Preview plus
explicit mock/test flags and an empty AI key; it accepts no user data and targets only
the one existing synthetic job above. Do not promote diagnostic deployments. No new
queue provider or Vercel support escalation is required by the current evidence.

Remaining rollout gates still include whole-pipeline background orchestration,
authenticated app integration, and the capped quality/cost evaluation. A working
single-step queue does not establish whole-import completion with the phone closed.

### Condition workflow orchestration — implemented locally, disabled (2026-09-30)

An additive `002_condition_workflows.sql` migration introduces authenticated parent
jobs, expiring clinical plans/checkpoints, and nonclinical parent-to-step links.
Mapping and independent verification now have a server coordinator. One bounded
paid step runs per queue delivery, with the checkpoint and budget reservation
committed atomically. A saved response can be reused after a worker interruption;
uncertain responses stop the parent without a paid retry. Queue handoff failure
resumes from the saved revision. Cancellation and expiry preserve incurred charges.
Cleanup remains active after disabling the feature, provided its migration exists.

`AI_CONDITION_WORKFLOWS_ENABLED=true` additionally requires the existing durable
and queue flags. The app separately requires `DurableConditionWorkflowsEnabled`;
neither new flag has been enabled or deployed. The app submits its complete source
plan, existing prompts and strict schemas once, then polls the parent. Source IDs,
manual exclusions, accepted identities, mapping reasons and independent verification
are preserved; the app validates the final result again before saving it.

Offline verification passed: real PostgreSQL concurrency, saved-response interruption,
automatic mapping-to-verification continuation, duplicate/result reuse, failed handoff,
owner isolation, cancellation, uncertain reservations, quota exhaustion and expiry.
Swift incremental tests (10) and the simulator app build passed. Type checking,
routing checks and deterministic response/ID rejection tests also passed. No paid
inference ran and no patient data was used.

Follow-up validation (2026-09-30): explicit Stop now cancels by canonical request
identity, including cancellation arriving before POST. The server retains only a
nonclinical cancelled identity for that race. Background polling cancellation does
not invoke Stop; failed remote cancellation is reported in the app. Settings reads
the latest parent cost across distinct child requests without double-counting the
ledger. Unknown child charges leave that parent estimate unavailable.

Both PostgreSQL suites, Swift Stop/routing checks, and the simulator build passed.
Preview `dpl_55rRLNmnE1fRrD5dBNn8ZJZwkqS8` applied migration 002 and completed
synthetic parent `7bfd5716-a0c6-48ef-a535-27f997293536`: a runtime submission
automatically advanced mapping to verification through two queue deliveries without
another app request. Both child requests and the parent report zero cost. The
Preview-only fixture executor and diagnostics exist only in temporary staging,
require mock flags and an empty OpenAI key, and must never be promoted to Production.

Do not enable the clinical pilot yet: authenticated app integration and quality/cost
evaluation remain outstanding.
Extraction/import sequencing is still app-owned. Clinical-quality evaluation with
production prompts remains mandatory before either new flag is enabled for the pilot.

### Capped quality evaluation — in progress, not accepted (2026-09-30)

Compiled Swift production prompts/schemas are exported by
`ConditionEvaluationContractTests` using `CONDITION_EVALUATION_CONTRACT_OUTPUT`.
The offline preparer validates seven synthetic cases through the actual server
request builder. Its first fixed-fixture paid Preview run used the production
worker and shared `evaluation-v1` ledger, with no patient data or direct-key bypass.
Parent `4a88cf5d-c312-4204-ab73-a2ab38d50a1a` completed mapping and verification
for existing pregnancy context at **$0.000415050 estimated API cost**, no unresolved
charge. It failed the required-link assertion; this is NOT a quality pass. Further
cases were held while inspecting the saved synthetic trace. Total evaluation ceiling
remains $1; no historical baseline has been reconstructed and no 10× claim is verified.

Full Swift suite: 263 tests, one skipped, zero failures. Settings report decoder,
privacy allowlist, unavailable amounts, budget arithmetic, and explicit Stop tests
passed; final simulator build passed. No phone install or Production promotion occurred.

#### Luna comparison and accounting migrations (2026-09-30)

Mini evaluation iterations spent $0.004722300 in total. The latest iteration still
accepted an unsupported migraine/hormone-investigation link and omitted related
history; it is not approved for clinical rollout. With explicit user approval,
Luna was tested under the SAME $1 `evaluation-v1` budget, not a new allowance.
Luna's initial seven-case run passed 6/7 at $0.002587100; the eye-history verifier
omitted required associations. Total across all iterations: $0.007309400, with no
unresolved charges. Further verifier evaluation remains in progress.

Preview `dpl_99nYeGfnY8VKQGLzMqSdBQAtvRPd` applied additive migrations 003–005.
003 attributes only newly incurred child costs to a parent; reused results cost
that new parent zero, while unknown historical attribution remains unavailable.
004 records initial/incremental/retry/development workload metadata without
invalidating request identities. 005 pins the server-selected model per workflow.
`AI_CONDITION_MODEL` accepts only `gpt-4o-mini` (default) or `gpt-6-luna`.
Changing that setting does not rebuild an existing workflow. Luna uses low
reasoning, 6000 maximum output tokens, Standard pricing, and explicit caching with
no breakpoints (no cache writes). Its reservation covers the entire model context
at the long-input rates; settlement uses the job's versioned pricing. Do not
reduce this reservation using an unverified character/token heuristic.

Both PostgreSQL suites passed, including model pinning, workload metadata reuse,
and parent attribution. Full Swift suite passed (263 tests, one skipped); simulator
build and Settings report checks passed. These diagnostic Previews must NOT be
promoted; Production and the physical app remain unchanged. Synthetic quality
results do not establish clinical completeness or a measured 10× improvement.

Final comparison: **Luna medium passed 8/8 synthetic cases (32 records)** at
**$0.003366400** for mapping plus independent verification. All evaluation attempts
combined cost **$0.012503900**, with no unresolved charges. Migration 006 pins
`AI_CONDITION_REASONING` (`low` default, or `medium`) alongside the model for every
workflow/step; changing deployment defaults cannot alter an in-flight job. Low
effort remained unreliable in the follow-up regression; do not enable it for the
clinical pilot based on these results. Full results, limitations, and the
nonclinical receipt are in `../docs/ConditionEvaluation-2026-09-30.md` and `.json`.
Production and the phone remain unchanged; authenticated app/pipeline rollout
gates above still apply.

### Single-account production rollout (2026-09-30, later update)

Superseded by the authenticated alpha rollout below.

Clean deployment `dpl_Rjni4PS6Xaob1U4z8SULFqWWkATy` is now Production. Durable
endpoints require the authenticated subject's SHA-256 digest in
`AI_PILOT_SUBJECT_HASHES`; Production fails closed if the list is missing or
malformed. Only the connected phone's account is enrolled. Other accounts retain
legacy processing. The enrolled account's legacy paid endpoints are blocked.
`scripts/production-check.ts` verifies this scope, migrations, Luna medium and the
shared $1 ceiling at deployment, without inference or database writes.

The corrected signed phone build passed authenticated usage/enablement checks.
After explicit approval, its 68-fact run completed and saved for $0.005695500
estimated API cost. Reopening preserved completion and the same job cost; all nine
sources and 68 facts remain. Shared tracked spend is $0.018199400, with no remaining
reservations. See `../docs/ProductionPilot-2026-09-30.md` for verification and limits.
Asha remains unenrolled; this is not a clinical completeness or 10× savings claim.

### Authenticated alpha rollout (2026-09-30)

At the owner's explicit request, production deployment
`dpl_5AWnfouVnZGeAFNVaZwjthwW2Kpk` removes the additional subject-hash allowlist.
All current and future Kinde-authenticated accounts can use durable processing
when AI_DURABLE_ENABLED is true. AI_PILOT_SUBJECT_HASHES is no longer consulted.
Authentication, per-owner job isolation, atomic cost reservations, and the shared
$1 ceiling remain enforced. No per-tester account enrollment is needed. Legacy
unbudgeted endpoints remain blocked for durable-enabled authenticated users; they
must use the updated app. This deployment does not start processing itself.
