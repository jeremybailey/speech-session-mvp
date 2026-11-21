# Service-owned summary workflows

Updated 2026-11-18. Founder service enabled and build 177 installed; physical-device acceptance remains pending.

## Accepted product and privacy boundaries

- Coordinate record summaries, practitioner handoffs and patient overviews on the service after the complete prepared-text snapshot is accepted.
- Keep original-file reading and transcription on the phone. On-device summaries keep their existing behavior.
- Use existing consent; no additional consent prompt or account-verification flow.
- Confirm completion only after the phone atomically saves the result in protected local storage and acknowledges its digest. Purge the server snapshot, drafts, rejected attempts, child inputs/results and upload fragments then. Hold clinical content at most until the original seven-day deadline if not acknowledged; retries do not reset that deadline.
- Provider and backup retention remain governed separately. No clinical contents in queue messages or operational logs.
- Preserve existing summaries, patient edits, category overrides, removed details and original evidence. No push notifications; retrieve results on return.

## Implementation

The versioned `summary-workflow-v1` contract has server-owned instructions and schemas. Independent passage extraction/checking feeds a three-way consolidation tree and original-passage omission audits. Inputs are bounded, passages retain their original IDs, and every result carries source/publication revisions. Record outputs retain category, visit section and explicit choice evidence; practitioner outputs enforce short fragments; overviews remain selective.

PostgreSQL stores parents, immutable input plans, step checkpoints, child history and an outbox. A private queue consumer executes up to three active children per owner. Child calls use the existing ledger, model policy and provider receipts. Duplicate delivery does not repeat a claimed inference. Dispatch leases expire after 60 seconds; a minute recovery cron recovers lost sends. Delayed successor messages avoid waiting for the cron between normal stages.

Transient rejected calls have bounded retries. Unknown provider outcomes stop for attention rather than triggering another paid call. Invalid outputs get one repair opportunity. Account budgets and a per-workflow call ceiling apply. Cancel-before-submit uses a nonclinical tombstone. Cancellation, expiry, supersession and receipt cleanup purge every attempt's clinical payload; late provider settlement cannot recreate purged rows.

Routes: `summary-workflows` accepts POST (submit/resume), PUT (checksummed upload parts), GET (read-only status), PATCH (digest receipt), DELETE (cancel/delete). GET cannot advance inference. `summary-workflow-queue` is private; `summary-recovery` requires the cron secret. Receipt, status and deletion remain available when inference is disabled.

App integration freezes requests before upload and uses protected, account-scoped local receipts. Record/overview publication guards remain atomic. Practitioner publication additionally compares the frozen history and previous saved handoff. Record deletion, clearing history and replacing history retain only metadata needed to cancel cloud work when online. Imported service jobs never resume automatically.

## Release sequence

1. Apply additive migration `013_summary_workflows.sql` using `AI_APPLY_SUMMARY_WORKFLOWS=1 npm run migrate:summaries`. Existing ledger migrations and budget are required.
2. Deploy preview with `AI_SUMMARY_WORKFLOWS_ENABLED=false`; verify migration and queue/cron installation. Enable with existing durable/queue flags and `AI_WHOLE_HISTORY_PROVIDER_BACKGROUND=true`. Start with `AI_SUMMARY_WORKFLOW_KINDS=practitioner`, then add `record,overview` after acceptance.
3. Verify minute scheduling availability, cron authentication, actual private queue delivery, outbox recovery and cleanup with synthetic inputs. The cron and completed-job retrieval must work with every phone offline.
4. Enable `ServiceSummaryWorkflowsEnabled` only in the founder app targeting that verified deployment. It remains false in source until live acceptance. Old in-flight local workflows continue on their original path.
5. Test start/lock/force-quit/return; compare actual midwife and prescription outputs; verify source edits, manual category changes, removals, cancellation and expiry. Benchmark queue/inference/checking/publication separately. Target acknowledgment p95 <2s after upload, ready-result retrieval p95 <5s after return, lost-dispatch recovery <2min.
6. Promote each workflow kind to pilot only after quality, cost, latency and durability checks pass. Rollback disables new submissions while preserving result retrieval/deletion. Do not shut down accepted-job workers during a normal rollback.

## Verification and remaining release gates

Local verification uses synthetic data, including a real isolated PostgreSQL database. Tests cover repeated submission, owner isolation, service-only completion with no client polling, receipt mismatch/replay, cancellation before upload, late completion after cancel, uncertain provider outcomes, failed-attempt cleanup, supersession, expiry, frozen requests, edited-overview protection and deletion tombstones. Regression tests cover existing record, practitioner, overview and data-transfer behavior.

A successful local build does not establish deployed queue operation, clinical output quality, latency or locked-phone behavior. Vercel CLI authentication was restored on 2026-11-18. The founder app targets collectivecare-story-lab.vercel.app, separate from the pilot. The user explicitly approved founder production deployment and migration.

Deployment dpl_FUxUiECpUzHjgf7ypnRvH2dvG9Vh is READY at https://collectivecare-story-g93pf154s-jeremy-baileys-projects.vercel.app. Migration 013 and production readiness checks passed with no inference. AI_SUMMARY_WORKFLOWS_ENABLED remains false. The live founder alias still targets dpl_9QgmNU8Tk6dGtw5oR8uAbmRHHTug. No phone update or pilot promotion occurred. The packaged summary endpoint returns 401 without patient authentication; private source paths return 404 after passing platform protection. Vercel CLI automatically created a project automation protection-bypass credential for its checks; patient authentication remains required. Credentials were not exported.

The first deployment was rejected by Vercel because Hobby permits only daily cron jobs. The disabled staging package omits the minute recovery cron; the source release configuration retains it. Activation is blocked until the user chooses a plan upgrade or an alternative durable scheduler and recovery is verified. Do not promote this disabled package as a complete background-processing release.

Before activation, complete load/latency measurements and fault injection for queue delivery/recovery, upload disconnects, and the actual provider background receipt path. The source feature flag must remain off until these gates pass.


## Pro upgrade and recovery schedule — 2026-11-18

After the user upgraded Vercel, deployment dpl_ALyq8GtZDcz7d6Z3STDBHnK5LtX1 reached READY with the minute recovery schedule accepted. URL: https://collectivecare-story-gtb82ihwq-jeremy-baileys-projects.vercel.app. It retains AI_SUMMARY_WORKFLOWS_ENABLED=false and does not switch the live alias. Accepted schedule configuration is not proof of actual recovery invocation; runtime verification remains outstanding.

A temporary fixed-fictional-input diagnostic was prepared only in /private/tmp/cc-summary-service-stage/api/summary-smoke.ts, protected by a newly generated test credential. It can submit only its configured synthetic owner/job, inspect that job, acknowledge/purge it, or cancel it. A proposed separate deployment enabling practitioner workflows and this diagnostic was rejected by automatic approval review pending explicit activation approval. No enabled diagnostic was deployed. Remove the diagnostic route, its function configuration and SUMMARY_SMOKE_* environment values before promoting a clean release.


## Live fictional workflow verification — 2026-11-18

User explicitly approved isolated processing activation and the temporary protected test endpoint. Deployment dpl_2wu5FdMHGznQLQWtU1goCwXsSTND completed synthetic job 5fac7511-6fdf-4099-89e6-937ee1008aa4 through three real provider steps with no client status requests for 45 seconds after acceptance. The first subsequent read reported all three completed. Output: “Left knee pain — intermittent after running” and “Physiotherapy — booked for Friday”, supported by the fixed fictional evidence. Ledger total: 541600 nano-USD ($0.0005416). This is one small functional check, not a latency percentile or load benchmark.

Acknowledgment returned received=true; subsequent scoped database counts reported zero parent payloads, zero child payloads, and zero retained step outputs. Temporary diagnostic source/function configuration was removed from the staged package. Live founder alias and phone feature flag remain unchanged. Lost-dispatch cron recovery, real-record quality, long-input performance, and physical locked-phone publication remain acceptance gates.


## Founder rollout and scheduled-recovery acceptance — 2026-11-18

The user approved continuing the full founder rollout after the explicit all-three-types, promotion, worker-routing and phone-install request. Clean release dpl_DQApiAtpfpixtt9HXphbVT784u6B was promoted to https://collectivecare-story-lab.vercel.app. It contains no diagnostic endpoint. Production flags AI_SUMMARY_WORKFLOWS_ENABLED=true and AI_SUMMARY_WORKFLOW_KINDS=record,practitioner,overview are saved in the founder project. The separate pilot was not changed. The active worker fence was updated from dpl_9QgmNU8Tk6dGtw5oR8uAbmRHHTug to this release. Vercel project metadata confirms its summary-recovery cron runs every minute against this release. Anonymous summary access returns 401 and private source paths return 404.

A guarded build-only check seeded three fixed fictional jobs without publishing queue messages and simulated a dispatch lease held for 30 seconds. No client request advanced these jobs. The deployed recovery timer picked them up. Each completed exactly three paid child steps, retaining the source revision and citations. Record output preserved today's sweep decline plus possible reconsideration, tentative newborn vitamin K preference, castor oil decline, and booked Nicole visit. Practitioner output used concise fragments. Overview retained the same qualifications. All parent/child payload and step-output counts were zero after receipt. Total ledger cost: $0.0031886. Actual inference-stage windows were approximately 35–39 seconds; this is a small functional test, not a long-record latency benchmark. The first verification ran too early (record still running); the subsequent check passed all three. Synthetic evidence and timestamps are saved in work/summary-recovery-2026-11-18.log outside the repo. Four temporary build-check deployments were removed after verification.

Build 177 succeeded and was installed on physical iPhone 00008140-001A74D10A93001C, bundle com.CollectiveCare.storylab. Its ServiceSummaryWorkflowsEnabled flag is true and its endpoint is the founder alias. Source flag and build version are updated. Remote launch was denied because the phone was locked. User was asked to regenerate Asha's record, allow submission, lock for two minutes, and report whether the result appears without Retry. Real midwife/prescription quality and physical locked-phone publication are not yet verified; do not promote to pilot on the strength of the synthetic checks alone.


## Physical-device acceptance confirmed — 2026-11-18

The user confirmed “Updated without Retry” after regenerating Asha’s appointment in founder build 177, allowing submission, locking the iPhone for two minutes, and reopening the app. This verifies the observed real-record locked-phone return and publication path. It does not establish force-quit recovery, long-run latency percentiles, or semantic completeness of the regenerated summary. Midwife content checks and prescription-only accuracy remain outstanding before pilot promotion.


## Copy summary and acceptance-scope correction — 2026-11-18

The user clarified that the medication summary under review came from a visit, not a prescription image. Review that actual visit against its source; do not request a nonexistent prescription image or mark a prescription-photo check complete. Added a founder record-menu Copy summary action in build 178. It copies the displayed saved summary in order, including headings and patient edits, without attachments or unrelated records, and gives a temporary confirmation plus an accessibility announcement. This enables the user to share just the intended summaries for content acceptance.


## Midwife copy review and quality correction — 2026-11-18

The user pasted the actual regenerated visit summary. Today's sweep decline, possible reconsideration and booked Nicole visit passed review. The vitamin K procedure/timing bullet overstated the tentative preference; ultrasound fluid assessment was conflated with the separate NST; bilirubin screening was phrased as unnecessary rather than a deferred decision at newborn assessment; back pain and family support overlapped across bullets. The user clarified the other medication record was also a visit, not a prescription image.

Two structural causes were identified: original-passage audits were concatenated after the earlier consolidation, and native completion appended local medication-reply fallback bullets after service verification. New plans reconcile all passage-audit outputs through bounded three-way merges with independent checks before publication. Saved legacy plans retain their original assembly path. Instructions distinguish procedural explanations from agreement, preserve deferred decisions and conditions, separate tests by purpose and combine overlapping topics. Service-generated results no longer receive unchecked local reply supplements; local-only processing keeps its fallback. Regression checks cover complete audit reachability, final-result selection, valid citations and preservation of differing source-supported choices. TypeScript passes; service suite 235 passed, 9 database-dependent skipped, 0 failures; founder 179 builds. Actual regenerated content must still be checked before claiming these semantic issues resolved.


Quality-fix deployment dpl_33JCbU3wEQ1Pt6kfYhDFnnyc33Lv is live on the founder alias and the active worker routing was updated successfully. Build 179 is ready but installation failed because the iPhone was unavailable (CoreDevice 4016). The user was asked to reconnect/unlock. Build 178 remains the last confirmed installed version; no new real-record accuracy pass has been claimed.


Build 179 installation confirmed on the founder iPhone on 2026-11-18 after the user reconnected and unlocked it. Regeneration and review of the new real-record output remain pending.


## Founder HTTP 422 follow-up — November 18, build 180

- Request metadata confirmed build 179 POSTs to summary-workflows rejected with HTTP 422 on the live founder release. No new job was accepted; the app's temporary-unavailability message was misleading.
- Reproduced Apple sentence tokenization emitting whitespace-only sentences for blank lines and PDF form-feed separators. The service previously rejected the whole request if any evidence sentence was blank. This is a reproduced compatible failure path, not a claim that the phone's private request payload was inspected.
- Service validation now drops only blank evidence after validating structure, size and unique IDs. Meaningful evidence and original citation IDs remain unchanged. All-blank or malformed submissions still fail. Existing frozen retry requests receive the same normalization.
- New app requests omit blank evidence. HTTP 422 now says the request was not accepted instead of implying it may continue in the background. Explicit Regenerate starts fresh even for legacy unfinished work; Retry continues saved work.
- Backend: 245 tests, 236 passed, 9 database-dependent skips; typecheck passed. Swift StoryTemplateTests: 24 passed. iPhone build 180 succeeded. Installation initially blocked by device connectivity; awaiting reconnection.
- Founder service release: dpl_G3q4uw57womyyXffGhf4ciqnGZpk. Promoted; worker activation and phone acceptance tracked below. Pilot unchanged. Real-record regeneration and content quality remain unverified for this fix.

- Build 180 follow-up: active worker routing verified for dpl_G3q4uw57womyyXffGhf4ciqnGZpk; temporary activation deployment removed. Live endpoint returned 401 without authentication and internal source path returned 404. Phone installation remains pending reconnection.

- Build 180 installed and launched on the reconnected founder iPhone on November 18. CFBundleVersion verified as 180. Awaiting Asha record regeneration outcome and copied summary; installation is not a semantic acceptance pass.


## Concise visit recap — November 19

The user confirmed build 180 produced a new full-record summary. It preserved key decisions and qualifications but reproduced counselling in long paragraphs. Updated only the service visit-template instructions, shared by draft, check, audit and reconciliation stages:

- Target 12–30 words per point, up to 45 when essential for meaning; this is a generation instruction, not destructive text truncation or a new response rejection condition.
- Decision and meaningful conditions first. Keep all distinct concerns, medicines, choices, open questions and agreed actions. Omit routine mechanisms, recipes, technique and other procedural teaching unless essential to the decision.
- Remove routine attribution and missing-decision boilerplate; retain clinically meaningful deferral and uncertainty.
- Related tests may share a short point while keeping each purpose explicit. Consolidate support arrangements. Do not invent conditional actions from conversational closing remarks.
- Existing saved summaries and patient edits are unchanged. Explicit regeneration uses the new rules. Detailed/practitioner/overview instructions are unchanged.

Validation: backend 245 tests (236 passed, 9 database-dependent skips); typecheck passed. This does not establish model-output quality; next real regeneration remains the acceptance check. No new iPhone build required. Founder deployment prepared: dpl_5KAEJhmtvPhUWKKjc5bgMpKNK69h.

Deployment completed: promoted dpl_5KAEJhmtvPhUWKKjc5bgMpKNK69h, verified active worker routing, and removed the temporary activation deployment. Live authentication returned 401 and internal source returned 404. Founder build 180 can regenerate with these rules; pilot unchanged.


## Confirmed provider failure recovery — November 19

User reported regeneration failed after transient UI slowness cleared. Request metadata showed successful submission/status HTTP responses. A build-only read-only diagnostic of the exact stopped workflow found 27 calls made, audit:1 with a persisted provider receipt and providerStatus=failed, but job state uncertain because usage/cost was absent. Audit:0 and audit:2 retained running requests with provider receipts. Parent was needs_attention/provider_outcome_unknown and its outbox had been removed.

Fix: distinguish confirmed generation failure from unknown billing. A persisted failed receipt can receive at most two delayed replacement attempts within the existing parent call/budget limits. The old unresolved charge keeps its full reservation. Completed steps and running request identities are preserved; absent/unknown receipts, incomplete output, cancellation and success are not classified as confirmed failures. Resume can recover older parents stopped by this misclassification only when all failed unfinished children meet the receipt/status/attempt gates. Genuinely unknown outcomes are still not retried automatically.

Validation: 246 tests (237 passed, 9 database-dependent skips), TypeScript passed. Added receipt classification checks and a database regression for idempotent resume, retaining the reservation, completing and purging all attempts; the database test remains skipped locally without a test database. No clinical data or credentials exported by diagnostics. Temporary diagnostic deployments removed. Founder release dpl_Fsmc1qpwWgnRea8m6m99QsaA6thC; activation and exact-job recovery tracked below. Pilot unchanged; no app install required.

Live recovery outcome: active worker routing verified for dpl_Fsmc1qpwWgnRea8m6m99QsaA6thC. Exact stopped workflow resumed from 24 completed steps and advanced to 26/40, with 33 total child calls. Provider failures persisted through the two replacement attempts; parent stopped as needs_attention/provider_failed. Read-only retrieval of the failed provider receipt confirmed error code server_is_overloaded. No further retry was requested; summary remains incomplete, last saved summary unchanged. All temporary activation/diagnostic deployments removed. This is a confirmed provider-capacity failure, not evidence explaining the separate transient phone slowdown. Cost reservations for missing usage remain held. The exhausted job will not resume with ordinary Retry under the current two-replacement ceiling; do not claim otherwise or silently restart the full record.


## Explicit unfinished-work retry — founder build 181

User requested clearer messages and Retry that resumes without restarting the record. The app now marks only an explicit Retry as user-requested recovery, fetches the current parent revision, and POSTs that revision to the existing workflow ID. Automatic reopening does not grant extra attempts. The server locks the existing workflow, rejects stale retry revisions by returning the current state, and queues only confirmed failed unfinished steps with incremented attempt identities. Completed outputs, running requests, source/publication revisions, archived receipts and cost reservations are retained. A repeated/concurrent retry cannot reset a completed step or replay the same retry grant. Existing overall call/budget limits remain enforced; terminal limits are surfaced without promising that Retry fixes them.

Messages no longer expose provider_outcome_unknown. Confirmed failures say progress is saved and Retry continues unfinished work. Expired, cancelled, superseded and limit failures do not offer a misleading Retry button in the error alert. No new whole-record generation is triggered by Retry.

Validation: backend 246 tests (237 passed, 9 database-dependent skips), typecheck passed; 25 Swift StoryTemplateTests passed; iPhone build 181 succeeded. Database regression added for concurrent revision-based retry, retained completed output, and continuation through completion; locally skipped without PostgreSQL. Founder service dpl_HZQA4rYfLAkqEM81P2gPVeVuEZCH promoted. Live exact-job resume verifies completed-output digests internally without exporting source text; installation/recovery results follow. Pilot unchanged.


Build 181 installed and launched; CFBundleVersion verified. Live retry initially preserved 26 completed checks on the older attempt. Further occupancy metadata revealed a newer same-record attempt created at 15:54 UTC; it was already progressing (23 child calls, merge checks active). The first verification targeted the older attempt, so it must not be cited as the current phone job's progress. Added a newest-attempt guard: a retry cannot revive an older replaced attempt, and its temporary processing data is retired. Added database regression for this case (subject to the same local PostgreSQL skip).

Final founder service release for build 181: dpl_3JSJ28f7UMnTxUZsozPoicH56jLV, promoted after tests/typecheck. Build-only activation retires the older attempt through the guarded resume function and checks preserved completed outputs on the current attempt. It does not reset the current attempt or start a whole-record replacement. Current progress/cleanup results follow.

Final verification: active routing is dpl_3JSJ28f7UMnTxUZsozPoicH56jLV. During verification a newer same-record attempt also superseded the 15:54 attempt, so its temporary outputs were correctly purged; the first digest-preservation assertion did not account for this legitimate replacement and the temporary build check failed. The follow-up check explicitly allowed supersession/acknowledgment cleanup and confirmed superseded rather than restarting that stale job. Do not claim the phone's latest summary completed: that was not verified. Build 181 is installed, tested, and launched; current explicit retry routing uses the phone's persisted workflow ID/revision, not the hard-coded IDs used by the temporary diagnostics. All temporary deployments removed. The available test suite passed; database-specific regression tests were added but skipped locally. Final user validation should use Retry on the current record, not Regenerate.

## Correction: timestamp self-supersession and founder build 182

The preceding final-verification explanation was incorrect. Metadata on November 19 showed no replacement newer than the 15:54 UTC attempt. The guard compared PostgreSQL microseconds with a JavaScript Date rounded to milliseconds, so a workflow matched itself as newer. This incorrectly superseded the current attempt and purged its temporary payloads. Original device records and the last saved summary were unaffected.

The guard now excludes its own ID and compares timestamps entirely within PostgreSQL. A regression explicitly sets a microsecond timestamp and verifies that Retry preserves the job and payload. Backend typecheck and 237 tests passed in the dependency-complete mirror; nine database-dependent tests remain skipped locally.

Private build-only recovery retrieved existing provider responses, verified response IDs and job metadata, and restored 25 completed portions plus the last submitted completed portion (26 total). No new inference was requested during receipt recovery. A narrowly scoped, one-time repair for that exact workflow accepts only its original owner and identical request hash, refuses a newer replacement/expired/acknowledged job, validates every restored output against the frozen source and original plan, and reattaches the source submitted by the phone. Completed steps remain completed; only unfinished steps can dispatch.

Build 182 shows Updating summary while old text remains visible, and Summary paused / Retry unfinished summary when work remains. The template menu offers continuation instead of starting a replacement while unfinished work exists. Build succeeded and installed on the founder iPhone. Deployment and actual continuation verification follow; do not infer completion from installation.

Founder repair release dpl_4uyuZpapCzCxiPbqjwMg31etpNLC was promoted and private activation confirmed background routing to that release. Build 182 installation confirmed. Phone Mirroring then required an unlock/relock; requested user action. Actual phone resubmission and completion are not yet verified. No new summary generation was triggered by this repair session.

### Founder phone recovery verified — November 19, 20:16 UTC

After the user unlocked/relocked the phone, Mirroring connected and build 182 opened Asha's record. Automatic resume reattached the identical frozen request to workflow 25942f1c-8c7d-40e5-9f90-190f6cf52a38; no Regenerate action was used. Metadata confirmed the original 15:54 creation time, 26 restored completed steps, and three newly dispatched unfinished steps (calls increased from 28 to 31). Progress reached 34, 36, 38, 39, then 40 completed steps. Final state completed, received=true, error=null, total calls=42: exactly 14 additional calls after recovery, rather than a fresh 40-step workflow.

Observed new text on the founder iPhone, vitamin K tentative preference, sweep declined today with reconsideration, and Nicole appointment on the 19th at 10 a.m. Processing indicator cleared. This verifies automatic continuation of this recovered job; no failure was induced solely to exercise the manual Retry button. Metadata-only cleanup check confirmed zero parent payloads, zero child payloads, zero retained step outputs after phone acknowledgment. The summary still has verbose bullets; this recovery verification is not a claim that concise-writing quality is fully resolved. Pilot unchanged.

## Final reading-layer brevity — November 19

Added final-publication instructions shared by Visit and Detailed record templates, without adding provider calls or changing the durable plan. Passage extraction, coverage checks and source citations stay complete. The final stage selects useful concerns, medication status, decisions, unresolved questions and agreed actions, consolidates related observations, and removes procedural teaching and conversational history. Target 8–18 words per bullet, normally 8–14 bullets for a substantial visit; explicit decisions and qualifications take priority over the target count.

Final record output validation rejects bullets over 28 words, routine patient/clinician reporting lead-ins, and missing-information boilerplate. It never clips text or deletes words mechanically. Existing bounded invalid-output repair can rewrite a rejected result while keeping its source citations. Earlier coverage drafts may remain detailed. Tests cover concise qualified decisions, tentative newborn care, deferral, booked timing, long paragraph rejection and source-draft preservation. Typecheck passed; 248 tests: 239 passed, nine database-dependent skips. Founder release dpl_3jr1pWx3FGHSy4xorPjtzdkbzotA; phone acceptance pending. No new iPhone build required. Pilot unchanged.

Generated-output checks on the active founder service passed: a fictional prenatal visit produced nine bullets (longest 13 words), preserving tentative newborn vitamin K, castor-oil decline, today's sweep decline/possible reconsideration, deferred bilirubin assessment, screening acceptance, a booked follow-up, support, and offered tests. A fictional short journal produced one 14-word bullet. Both results were acknowledged via the normal receipt endpoint. These are actual model-output checks, not just static validators; fixture content was explicitly fictional, and no patient source was uploaded through deployment files. The phone was in use, so Asha's regenerated output remains unverified pending unlock/lock handoff. Founder routing confirmed dpl_3jr1pWx3FGHSy4xorPjtzdkbzotA.

### Real-record check exposed remaining verbosity; revised limits

The first real Asha regeneration completed/was acknowledged (41 calls), but on-device inspection failed the editorial goal: related symptoms remained split, incidental cool-hands commentary survived, and bullets used most of the 28-word allowance. The in-app Cancel control eventually closed an unchanged editing draft; an attempted app restart was blocked by automatic approval review due to potential unsaved edits and was not executed.

Revised final publication to a 6–12-word target, 18-word hard maximum per bullet, and 200-word maximum for the whole recap. The prompt explicitly selects essential topics rather than shortening every extracted fact; related symptoms become one concern, support one point, and incidental normal observations/history are omitted. This remains source-grounded rewriting, never mechanical truncation. Added whole-recap budget and 19-word bullet rejection tests. Typecheck passed; 249 tests, 240 passed and nine database-dependent skips. Founder release dpl_F9nTCuxEGo9E3vtXDSPTXwr3swCx promoted, worker routing verified. Second real-record regeneration started through the phone's template menu; acceptance pending.

### Final editor conflict resolved and phone result verified

Second real-record run stopped after 39 completed checkpoints because the publication draft exceeded the new limits: 236 words, maximum 20 words per bullet. Saved summary remained unchanged. A metadata-only diagnostic established those counts without logging clinical text. The final stage still inherited coverage instructions to return the full checked inventory, competing with the selection/editing task.

Publication now has its own safety-and-editor instructions, a mainDraft, and separately labelled supportingEvidence. It does not inherit the extraction instruction to restore all distinct details or return the full inventory. Category/choice semantics and citation validation remain. The record-publication stage alone can use up to three bounded repair attempts (earlier stages retain one); all repairs remain within the workflow call budget. Added a test distinguishing final-editor input from extraction input. Typecheck and 241 tests passed; nine database-dependent tests skipped.

Founder release dpl_8tYxNyB8Qh7DSaGnnfDGtyhRnJWK promoted and routing verified. A private, narrowly guarded recovery queued the existing failed job 10a015b2-0b20-440b-8c29-dfa733faed86 only after verifying 39 saved completed steps, a single rejected final step, no newer replacement, and unexpired work. Two additional final calls completed it (41 to 43 total); no completed source check was replayed. Tapped Retry in the phone alert to reconnect to the same job. Service completed all 40 steps, received=true, and cleanup confirmed zero parent/child payloads and zero retained step outputs.

Observed Summary updated on the founder iPhone and short bullets within the 18-word/200-word validation limits. Vitamin K retained tentative acceptance and timing question; the sweep bullet retained today's deferral and possible reconsideration next week; Nicole booking retained the 19th at 10 a.m. Wording is substantially shorter; do not claim every phrasing is ideal (e.g. the generated sweep uses deferred rather than the source's declined). No patient edits were saved by the agent. No app restart occurred. Pilot unchanged.


## Practitioner brevity and durable recovery — builds 183–185

Applied the record recap's selective final editor to practitioner summaries: topic-led fragments, 6–12-word target, hard maximum 18 words per bullet and 200 narrative words, existing headings, material concerns/actions, medication names without doses/schedules, source-supported abnormal labs, preserved uncertainty and decisions. Structured labs remain outside the narrative budget and retain their saved values. Saved older summaries remain readable. Presentation constraints run only at final publication; intermediate source/citation checks remain strict. A fictional generated fixture passed with ten concise bullets and no normal hemoglobin, medication doses, or reporting boilerplate.

A real practitioner job initially stopped on working-draft shorthand validation. After correcting that gate, the app's error handler incorrectly abandoned its saved operation; tapping Update created a replacement. Build 184 preserves resumable operation IDs and frozen requests, retries unfinished work, and recovers only the latest diagnosed failed operation after checking its service state. Cancelled, expired, superseded and older operations cannot be revived. This correction was communicated to the user.

The replacement f7bb2867-eb88-7017-7d34-41abeb5abfeb reached 63/107 completed steps and stopped with a confirmed provider max_output_tokens receipt at 6,000 tokens. Whole-history overview output now reserves 16,000 tokens for structured merges; already queued requests retain their original reservation limit. Only confirmed terminal output-limit receipts can retry, bounded to two attempts and the existing workflow/global budgets. Unknown outcomes and content filters are excluded. Explicit resume retains every completed output. Founder deployment dpl_5P1qvZsFf2DH5NgHoRXddBYRZMo5 promoted and worker routing activated; the same workflow subsequently completed all 107 steps at 111 calls. No completed step was reset.

On returning November 20, the latest practitioner workflow was 864acf8b-64c7-1a28-8a35-e122b04e0f49, completed at 109 calls/107 steps, received=true, zero parent payloads and zero retained step outputs. Do not confuse this later workflow with the recovered f7 job. iPhone preview and PDF showed short topic-led fragments. PDF colors were limited to abnormal value/arrow. Real output is not a full clinical-accuracy signoff: its vitamin K timing-question label says unanswered although the supplied visit transcript contains an answer. That semantic issue remains an acceptance concern; no clinical source or patient writing was silently edited to conceal it.

Build 185 additionally recognizes calculated LDL and non-HDL names and Total cholesterol, and collapses compatible duplicate display readings only within the same source record/day with identical result/units/specimen/context/abnormality and no conflicting ranges or distinct explicit times. Stored lab entries are unchanged; conflicting results, different sources, and distinct timed measurements remain. Tests cover those boundaries. Backend: typecheck passed, 245 tests passed, nine database-dependent skips. Swift practitioner tests: 28 passed, including PDF rendering and lab trends. Founder build 185 compiled successfully. Pilot service/build unchanged.


Build 185 installed and reopened on the founder iPhone. Observed the PDF preview with abbreviated LDL (calculated), Non-HDL and Total cholesterol; only value/arrow colored. Existing duplicate-looking readings from nonmatching source/context identities remain visible: do not claim the observed document is fully deduplicated. The conservative display rule does not combine different source records. Latest summary was received; temporary diagnostic deployments created for this task were removed. Final clinical wording and cross-record lab deduplication remain limitations, distinct from the completed brevity/retry implementation.


## Build 186 — record rendering and foreground reconnection

The record reading canvas previously recomputed normalized text, generated detail headings and every bullet/detail evidence match in its SwiftUI body. It now caches the reading projection by full session value, health-facts publication revision and availability of opening facts. Record edits, removal/Undo, category changes, source updates and published facts invalidate the cache; focus/progress/scroll redraws reuse it. This removes the identified repeated matching work; an on-device scroll trace remains needed to quantify hitch improvement.

Practitioner foreground recovery no longer returns merely because generating remains true. It cancels and awaits only the suspended local wait, retaining the same operation/request/service job, then reconnects. Reconnection precedes expensive workspace reload/cancellation flushing. The reconnect guard prevents competing foreground attempts and the cancelled task's deferred restart. Copy uses Preparing summary… during service work and suspension. No service cancellation or fresh summary request is introduced by this path.

Build 186 compiled and installed on the founder iPhone. All 28 practitioner persistence/template tests passed. A fresh-run failure investigation hit database SQLSTATE 53000 before any workflow metadata could be read; hosted diagnostics confirm quota/limit/exceeded. No failed job was reset or regenerated. Live service unchanged; temporary check deployments disabled summary workers and were never promoted. Locked-phone acceptance cannot be completed while the database refuses status reads.

Vercel Storage confirms the founder database is Neon Free, independent of Vercel Pro. Its integration settings expose Launch at $0.106/CU-hour and $0.35/GB-month and say the plan applies to all four connected databases. Neon console SSO requires email verification; Vercel plan controls are available. Requested explicit approval before changing paid database plan. No plan change made pending that answer.


## Approved Neon Launch upgrade and build 187

User explicitly approved Launch at the displayed $0.106/CU-hour and $0.35/GB-month, applying to all four databases in the existing installation. Selected Launch and Update in Vercel; observed Installation has been updated. Subsequent hosted queries succeeded. No credentials changed or exported, no access widened, and no app processing budget increased.

With database access restored, the latest fresh practitioner run a64ebb0d-b944-9d23-0e7d-9fa8e0b02396 was needs_attention at 237/238 steps, calls=241. Its completed provider final had 13 bullets, 149 total words, maximum16 per bullet, no prose violations, but three qualifiers exceeded the separate 12-word sublimit. That sublimit was stricter than the agreed whole-bullet limit. Both server and app now allow qualifiers to use remaining space (up to16 words), while preserving the unchanged 18-word whole-bullet and 200-word whole-summary limits, short topic requirement, citations and other validation. Existing final text passes unchanged; no clipping or medical rewriting. Added matching app/server regression tests including rejection above18 words.

Backend typecheck and246 tests passed (nine database-dependent skips); all29 Swift practitioner tests passed. Build187 compiled and installed. Founder release dpl_FVzw3ckwMjSGK4hMgTCe1bWWjUbo promoted; worker routing verified. Guarded recovery required the same latest unexpired parent,237 completed saved steps, a single completed provider final and successful validation. It queued only publication. The job completed238/238 at the unchanged241 calls, received=false at final check. The phone was in use, preventing Mirroring; collection in the app, scroll performance and lock/unlock acceptance remain unobserved. User should open the practitioner share summary to collect the completed result, not regenerate. Clinical temporary content remains until receipt/expiry. Pilot deployment unchanged (the authorized Neon plan change applies to its shared integration).


## Build 188 — visible recovery and receipt-less explicit retry

The 12:53 screenshot belongs to a new practitioner workflow (9efca093-9a64-dab1-1e57-5be108109952), not the completed build187 workflow. Metadata-only inspection found76 completed steps of241, calls79; check33 was uncertain without a provider receipt, draft36 remained running without a receipt, and check39 had a receipt. The transport/receipt-loss cause is not yet proven. No clinical text was printed by diagnostics.

The share sheet now reconnects persisted work when opened and offers Retry unfinished summary alongside its error, retaining the previous summary. Successful generation and confirmed completed saved operations clear the error. Build188 compiled and installed. Device visual acceptance remains pending.

An explicit revision-checked retry can replace a receipt-less uncertain step once, only after10 minutes. It also retires stale receipt-less running children within that workflow before evaluating retry. Automatic recovery still never repeats unknown requests. Known provider receipts, completed outputs, source/publication revisions, and original child identities survive; uncertain charges remain reserved against the existing budget. Concurrent explicit retries create one replacement. Newer workflows and expired data retain their existing protections.

Backend typecheck and247 tests passed (nine database-dependent skips). All18 summary workflow tests also passed against an isolated local PostgreSQL database, including concurrent explicit retry, unchanged completed draft, retained unknown charge, and completion. Founder release dpl_F9fUkkL2bdAVLHV6TZ4ruPW8VwZC promoted. Recovery progress is recorded separately below; do not claim final completion or phone-lock/scroll acceptance from deployment alone.

Guarded explicit resume succeeded on the same workflow. Observed running at77/241 saved steps, calls82 (76 steps/calls79 before recovery), proving advancement without a full restart. Final completion and app receipt remain pending; no claim of a finished summary. Build188 installed successfully.


## Build 189 — distinguish received-result publication errors

Metadata confirms workflow9efca093 completed241/241, calls245, received=true, with zero parent payloads and step outputs after receipt cleanup. User still sees “Try generating it again.” That string originates in the app's combined StoryEditError/SummaryStageFailure handler; it does not indicate another provider failure. Exact local cause remains unconfirmed without device inspection.

Separated format/source-reference validation messages from stale source/publication revision conflicts. Keep local request/receipt after validation/save failures. Permit narrowly diagnosed older failed StoryEditError operations to reattach only after checking the same service job and latest persisted parent. Genuine stale revisions remain protected and explain why a new generation is needed; a concurrent already-completed parent reloads its saved summary instead of showing an error. No validation or source-revision checks weakened. Build189 compiled; installation/phone acceptance recorded separately when observed.


## Build190 — source comparison independent of enumeration order

User's screenshot confirms staleRevision, not formatting rejection. Exact source of that local conflict remains unverified. Identified a false-conflict path: full snapshot JSON compares lab array order, while HealthMemoryProjection has no stable identity tie-break for equal-status/equal-title facts. Publication now compares sorted full encoded evidence and lab objects, retaining identities, all field values and duplicate counts. Existing shared-summary equality and queued-parent guards remain unchanged. Frozen service request is untouched, allowing reuse of the downloaded receipt. Genuine content edits still require a new generation.

All30 StoryTemplateTests pass, including reordered evidence/labs accepted and changed content, removed lab and changed duplicate counts rejected. Build190 compiled. On-device publication acceptance remains pending; do not claim ordering was this user's confirmed cause.


## Build191 — persisted publication baseline

User regenerated after another stale-revision message. New job75517e80-76b0-ba9a-5834-bd6ac5ba8111 observed running47/241, calls51, no error. No restart or mutation of this workflow was performed.

Found a reproducible false conflict: recoveredStorySharedSummary adds source-matched lab readings to a display copy without persisting them; generation froze that display copy as publicationSummary but publication compared it to the raw persisted summary. New requests freeze the persisted summary. Existing frozen requests may match the current reconstructed display copy, which still includes current patient edits; source comparison and queued-parent checks remain required. Regression verifies recovery of enriched lab summaries succeeds and a subsequent patient-name edit blocks publication. All30 summary tests pass; build191 compiled. This is a verified code defect, but its causal role in this device's failure and live publication acceptance remain unconfirmed.


## Final punctuation rejection — founder service repair

Workflow75517e80 stopped at240/241, calls246, invalid_summary_output on final:3:0:check attempt3. Metadata-only inspection:11 points,113 words,max14 words, no fragment/prose/unknown-citation/metadata-citation/boilerplate failures; six points contained semicolons, zero terminal periods. This is separate from phone publication revision conflicts.

Practitioner terminal validation now splits top-level semicolon qualifiers into separate topic-prefixed bullets before validation, mirroring the existing share renderer. All wording, metadata and citations remain; quoted/parenthetical semicolons and malformed empty items are not rewritten. Length, total words, source references, clinical qualifiers and other validation still apply after formatting. Tests248 passed,9 database skips; typecheck passed. Founder release dpl_HzGH1np88of59ncakeEHRafoZyC6 promoted and worker routing updated. Guarded recovery verified the same latest unexpired parent,240 saved outputs, one completed provider final, and full successful validation. Only publication was requeued; calls stayed246. Completion/phone receipt checked separately.

Confirmed service completion241/241 at20:35:50 UTC, calls unchanged246, no error, received=false. No new provider calls were required. App collection/publication remains to be observed; do not regenerate.


## Build192 — dated bullets and compact practitioner workflow

User confirmed previous recovery worked. New practitioner requests select optional pipeline compact-v2. Persisted requests without that marker retain their original plan and hash. Compact workflow packs up to96KB/source batch, checks each draft against its source, uses bounded eight-way intermediate merges, audits every original batch, consolidates audit results, and performs a final independent publication check. Owner concurrency remains3 and budgets unchanged. A representative48-source synthetic history reduces244 planned stages to37 (85% fewer). This is stage-count evidence, not measured wall-clock latency or a Granola speed claim.

Each summary evidence group carries a date label and only groups details with the same label. Source event/relevant dates are distinguished from fallback Record dates; missing dates remain unknown. The service derives bulletDates from cited evidence IDs, never free-form model-invented dates. The app saves metadata with the summary and renders a smaller calendar label beneath each bullet; PDF includes the same date text. Older summaries without metadata remain readable. Regeneration is required to add dates to previously saved summaries. Date metadata is presentation-only for source equality, and older frozen requests reconstruct the prior grouping to avoid migration-induced publication conflicts.

Backend250 tests passed (9 database-dependent skips), typecheck passed; Swift31 tests passed. Verified PDF text and rendered synthetic date-label layout. Founder build192 compiled and installed; release dpl_9vGnufDX62kcbjS5RoPuczQkdmrK promoted and queue worker routing verified. Live large-history elapsed time and physical-iPhone date-label acceptance remain unmeasured. Pilot unchanged.


## Build193 — one event date per bullet

User clarified date context means the latest cited event date only; record/upload dates are irrelevant. Shared app/PDF presentation now filters out Record labels and unknown/relative/unparseable dates, chooses the latest valid explicit Date label, and displays one plain date without a prefix. Partial year/month precision remains partial. Raw evidence and saved metadata remain unchanged, so existing dated summaries adopt the rule without regeneration. Bounded thread-safe rendering cache avoids reparsing date arrays on scrolling redraws. Dates absent from old summaries cannot be invented.

All31 summary tests passed, including event ordering, ignored record dates, unknown/invalid dates and partial precision. Rendered PDF visually checked with a single20 Oct2026 event date despite a newer record date. Physical-device visual acceptance remains pending.


## Build194 — inline PDF event-date tags

User clarified the ambiguity was PDF-only. App date layout remains unchanged. PDF bullets now append the latest supported event date as a small neutral capsule in the same text flow; nonbreaking spaces keep the complete date together when wrapping. CoreText paints the background while retaining selectable date text. Existing dated summaries need only a new PDF export, not regeneration. All31 summary tests passed and synthetic PDF visually verified. Founder build194 compiled successfully; device installation tracked in /private/tmp/cc-install194.log.


## General essential clinical context rule

Practitioner drafting, checks, audits, consolidation and final selection now prioritize documented context that materially changes interpretation before individual Clinical Snapshot concerns. This is a general relevance rule, with nonmandatory examples (pregnancy/postpartum, major active conditions, surgery, immunosuppression, significant allergies), not a patient-specific exception. Preserve citations, timing and historical/current distinctions; never extrapolate current gestational age or ongoing pregnancy from an older encounter. Abnormal-only filtering applies to investigation results, not essential context. Existing brevity limits remain.

Backend251 tests passed,9 database-dependent skips; typecheck passed. Regression verifies instruction propagation through every compact practitioner phase and exclusion from record prompts. This verifies prompt wiring, not a guarantee of model coverage on real records. Founder release dpl_2gJ2pDQF8dvpwRMqcFn4AjTY2uy6; no app rebuild required. Existing summaries need regeneration to adopt the content rule.


## Build195 — content-led practitioner summary length

Removed the practitioner-only200-word total ceiling from service publication validation, initial/retry prompts and app handoff validation. Keep18-word bullets, cited meaning and all existing safety/format checks. Prompts retain distinct relevant context, concerns, medications, decisions, questions and actions; no fixed page target. Record recap limits remain unchanged. Regression checks accept30 distinct concise practitioner bullets exceeding200 words while existing overlong-bullet and record-limit checks remain. Backend251 tests passed (9 database skips), Swift31 passed, typecheck passed. Founder service release dpl_Edb9yTCu8Cxv1gcUtxUAyiZo1qF9; build195 required so app accepts longer handoffs. Regenerate after installation to adopt the changed content selection. No guarantee that every relevant point is retained without real-output review.


## Build196 — practitioner summary step progress

The existing service status response supplies completed/total counts. Optional main-actor progress callback in summaryWorkflow exposes valid nonnegative counts (total>0, completed<=total) from existing polling with no extra network requests. Practitioner share preparation and the home entry display Preparing summary… X of Y steps. Counts are completed processing steps, not elapsed-time estimates. Before the first valid response, retain the generic label. On reopen/resume, retrieve current saved service counts. Only changed labels publish UI updates. Existing animation and reset-during-generation protection accommodate progress labels. Other workflow callers retain unchanged behavior. Founder build196 compiled; physical-device progress behavior still requires an active summary run.


## Build197 — labeled record-date fallback

The shared app/PDF date formatter prefers the most recent valid event date. Only when none exists, it uses the most recent valid linked record date with Recorded prefix. Unknown/invalid dates are omitted; partial month/year precision is preserved. No data mutation, backend change or regeneration is needed for saved summaries already carrying record-date metadata. Summaries without metadata remain undated. App layout unchanged; PDF retains inline trailing capsules.

Swift31 summary checks passed, including event priority over newer records, multiple record dates, invalid events with valid fallback, absent dates and partial precision. Rendered synthetic PDF checked for short bullets, wrapped text and partial-date fallback labels. Founder build197 compiled successfully; install log /private/tmp/cc-install197.log.


## Build198 — practitioner PDF visual refinement

PDF now uses a32-point branded serif title, small copper wordmark, patient-name hierarchy, warm ink, subtle separators and compact warm date capsules. Topic phrases before the em dash are bold; body11.5pt,4pt line spacing and8pt bullet separation improve scanning. Continuation pages carry a small summary/patient header and a right-aligned page number, keeping printable white paper and selectable text. Lab value/arrow color behavior and source wording are unchanged. No regeneration required; export again.

All32 summary tests passed, including long paragraphs, repeated table headers, date fallbacks and multi-page content preservation. Rendered short and multi-page synthetic PDFs with bundled Garamond/Inter fonts and visually checked first/continuation pages. Founder build198 compiled; device install log /private/tmp/cc-install198.log.

### 2026-11-20: summary scheduling speed work

Provider completion webhooks now recognize current summary children and wake the existing parent through `ai_summary_outbox`, rather than waiting for its next scheduled poll. Queue publication failure leaves durable recovery work; duplicate callbacks cannot create a new model request, and completed/cancelled/expired parents or superseded child attempts are not revived. Retry eligibility remains checked by the coordinator.

New practitioner workflows can opt into `AI_SUMMARY_PARALLEL_V2=true`, which freezes `parallel-six-v1` on submission. Default and existing workflows retain `baseline-three-v1`. Models, reasoning effort, prompts, validation, budget reservations, and clinical coverage are unchanged. The higher-concurrency flag remains OFF pending real-provider timing/rate-limit evaluation.

Validation: TypeScript passes; full suite 261 tests, 253 passed, 8 unrelated database-gated tests skipped. Summary database integration tests ran against isolated local PostgreSQL, including new six/three policy preservation, duplicate completion wakes, cancellation and missing-child notifications. No production records used.

`vercel-openai-proxy/scripts/benchmark-summary-scheduler.ts` runs only against isolated localhost PostgreSQL and uses synthetic evidence with simulated 150 ms responses. Across three repetitions of a 34-step compact workflow, baseline times were 3.144/3.003/3.029 s and six-way times 2.545/2.449/2.385 s: median 3.029 to 2.449 s (~19% less elapsed time). Every run made 34 simulated calls. This measures scheduler behavior, not real model latency, quality, or a claimed 2× end-to-end improvement. Real-provider benchmark, instruction-cache economics, and merge-reasoning experiments remain outstanding; no paid Fast tier enabled.

Founder rollout: `dpl_GgZRLyc3E8ADThEhNudspo5scy6m` promoted and runtime routing verified. A rollout check required explicitly applying the backwards-compatible policy-column migration; the old release was temporarily restored until checks passed. Six-way execution remains OFF. Timing-only production baseline over the preceding seven days: 1,155 completed practitioner child calls, median observed started-to-finished duration 23.7 s, p95 44.7 s. This includes collection/settlement latency and is not pure provider inference time. No clinical text was logged. No iPhone build required for this service-only change.

### 2026-11-20 continued: measured experiments and policy handoff

Fictional provider batch benchmark (same Luna/medium/default tier), six cases × three repeats per setting: median 18.972 s at concurrency three versus 10.676 s at six. All 36 calls completed. Checked concepts passed in 18/18 faster-setting cases versus 17/18 baseline cases. Total estimated cost $0.0085575 versus $0.0084863 (~0.84% higher; no premium tier). This is component throughput, not whole-summary latency.

Intermediate merges were separately replayed with medium versus low reasoning on fictional data. All 12 outputs passed format, checked-concept and attached-qualification probes. This experiment does not justify lowering reasoning for extraction, source audits, final merges or publication. The new opt-in policy changes only `phase=merge` with a `merge:` key; independent merge checks remain medium.

The full-workflow experiment exposed legacy queue consumers using an older execution-policy implementation. Consequently, the initial combined-policy result is excluded. New policies are versioned `parallel-six-v2` and `parallel-six-low-merge-v2`. Transaction-local database fences prevent older coordinators from advancing/publishing or leasing dispatches for these policies; current queue consumers and dispatchers also require the active deployment. Existing v1 workflows retain their policy. Unknown policies cannot be advanced. Temporary reservation pressure now waits for admitted work instead of immediately failing the summary; hard budget exhaustion still surfaces.

Production readiness checks now require both database fences. Regression tests include rejection of legacy advancement/dispatch, complete persisted reasoning selection after flags change, cancellation, receipts, duplicate notifications and budget backpressure. Real-provider isolated validation is pending; no public higher-concurrency or lower-reasoning setting enabled yet.


## Founder service — measured summary speed trial, 20 November 2026

Added frozen per-workflow execution policies, six-way admission for independent practitioner stages, and low reasoning only for intermediate merges that are followed by original-source audits. Extraction, checks, audits, final merges and final publication remain medium. Existing requests retain their original policy; budget admission now waits for pending reservations to settle rather than rejecting otherwise unfinished work.

An evaluation exposed deployment-pinned queue consumers applying older settings. The new active-deployment check and additive database admission/dispatch fences prevent older releases from admitting or publishing v2 work. Both speed-enabled and speed-disabled releases understand v2 policies, so rollback preserves unfinished jobs. Recovery-only release dpl_FYR1bmNPZVs8encoRjDey9jnYtcB was promoted and its worker route verified before speed enablement; speed flags remained off. Use this guarded release for rollback, not a pre-v2 release.

Validation: typecheck passes; 258 tests passed, 8 unrelated database-gated skips, zero failures. Real isolated PostgreSQL tests cover frozen policies, deployment fencing, full multi-batch completion, callback deduplication, cancellation, budget backpressure and receipt cleanup. Metadata-only provider lifecycle/collection-delay diagnostics were added; no source text is logged.

Fictional provider component tests: six concurrent calls had a median10.676s versus18.972s for three, approximately44% less elapsed time; total cost differed by less than1%. Intermediate merge tests preserved the checked concept/qualifier probes in12/12 outputs and reduced reasoning tokens. These are limited synthetic probes, not clinical validation or a whole-summary speed claim. Initial whole-workflow timing samples were confounded by overlapping tests and legacy workers; they must not be cited as proof of a six-way speedup. The guarded whole-workflow comparison and its rollout decision are recorded below when complete.


Rollout decision: enable six-way independent-stage admission with medium reasoning throughout (parallel-six-v2). Keep low intermediate-merge reasoning OFF. Although12/12 merge probes preserved checked qualifiers, the second complete low-merge output dropped a booked November17 follow-up that baseline and the first low-merge run retained. This does not establish a deterministic regression, but is sufficient to withhold the more aggressive setting.

Observed v2 workflow times: baseline306.85s; low-merge variants242.91s and245.01s;34 calls each, roughly$0.11 each. A previously removed deployment continued its in-progress build, causing overlap; the worker route also changed during baseline. These are not isolated timing samples and do not establish a causal end-to-end percentage improvement. Child policy assertions passed. Current medication status, declined intervention, conditional MRI, abnormal LDL trend, ferritin, transplant context and penicillin anaphylaxis were retained in reviewed final outputs; historical antenatal topics were omitted across baseline and variants. Tests remain limited fictional evaluation, not clinical equivalence.

Founder release: dpl_8LUJHgFYTvauWHx7rxqNaqPop61H, parallel=true, low-merge=false. Guard-compatible rollback: dpl_FYR1bmNPZVs8encoRjDey9jnYtcB. No app rebuild, premium service tier, model training, patient-text cache, or pilot rollout. Existing jobs continue with their frozen policy. A new practitioner summary is needed to exercise parallel-six-v2. Whole-summary user latency remains to be measured; do not claim2x.

Activation verified: public alias and active background routing both point to dpl_8LUJHgFYTvauWHx7rxqNaqPop61H. All10 fictional workflow payloads and48 standalone fictional provider payloads were purged; zero benchmark source/output payloads remain in service storage. Usage metadata and local fictional evaluation results remain for review. Temporary deployments removed; isolated test database stopped.


## Build199 — reference-aligned practitioner history and PDF

Aligned all seven section purposes with the supplied fictional practitioner reference. Preserve dated historical milestones, prior procedures, resolved conditions, treatment responses, family/social context, functional impact and stated priorities. Distinct current/history/treatment perspectives can coexist; repeated wording is discouraged. Existing concise fragments, medication names without doses, abnormal-only results, qualifiers and source/publication revision protections remain.

A real-provider fictional check demonstrated that draft/audit retained older history but final selective editing reduced it to three recent/background points. New final strict-schema responses include historyIDs against a requiredHistory checklist derived from the persisted audited draft. Validation requires every listed history point to be represented once, under the history heading, with supporting original citations; invalid final output uses the existing bounded final-step repair. Duplicate semicolon formatting fragments retain coverage IDs only on the first fragment. Legacy responses without the new schema field remain readable and resumable. This is structural coverage plus source review, not a guarantee that every clinical fact is correct.

The revised fictional reference check retained14 history points, including pregnancy/delivery, resolved postpartum leakage, appendectomy, back-pain course and prior gluten trial. Four logical stages retained; replay reused earlier provider receipts and changed final editing only. Temporary workflow and direct-provider payloads purged after review. No real patient sources used in this check.

PDF: patient-focused title, prepared date, warm highlighted snapshot, compact dated history table, treatment/status table, abnormal-lab table with sparklines and earlier readings, repeated table headers and continuation identity. Only lab values/arrows receive abnormal/improving colour. Explicit unambiguous historical dates take precedence over record-date labels; multiple ambiguous dates remain in the text without guessing. Source text remains selectable. Full fictional example renders in three pages without cutting history; no fixed page limit imposed. Brand typography and palette retained rather than copying reference branding.

Validation:259 backend tests pass,9 database-gated skips; TypeScript check passes.35 Swift summary/PDF tests pass, including multi-page history preservation, repeated headers, explicit dates and numeric-unit ambiguity, labs and full reference rendering. Founder build199 compiled and installed (latest install sequence19992). Rendered all three fictional preview pages and inspected layout. Service dpl_3ZfqyzKuiAzZsmfhTpZ2famWxJ2g promoted and active worker routing verified. Parallel admission remains6; all reasoning remains medium. Pilot unchanged. Existing content requires explicit regeneration for new section/coverage rules; existing saved summaries can be re-exported for the layout. Physical-phone visual review of the new PDF remains user acceptance.

### Founder build 200 — Health History years

Health History PDF dates now display years or explicit year ranges, without a Recorded prefix. Event dates remain preferred; record dates supply the fallback year. Other date displays are unchanged. All 35 StoryTemplateTests passed; the rendered history table was visually checked.

### Founder build 201 — Undated history

Health History now uses only event dates or unambiguous years retained in the historical point. Record-date fallbacks no longer appear in this section: undated events display a dash in both app and PDF. Ordering and other sections are unchanged. The 35 summary template tests passed.

### Founder build 202 — Historical date anchors and PDF date style

History years require an explicit year in the point itself; citation dates no longer supply historical years. Relative anchors and documentation dates display a dash rather than a misleading year. Sequence is preserved. Other PDF dates use smaller grey text without capsule backgrounds. All 35 template tests passed.

### Founder build 203 — Calculated historical years

Explicit year offsets with explicit calendar anchors now resolve to years/ranges in Health History. About 10 years before Sep 2024 yields c. 2014; 5–6 years before Sep 2024 yields 2018–2019. Approximation is preserved, source wording is unchanged, and unanchored ages/seasons do not use upload dates. All 35 template tests passed.

### Founder build 204 — Ongoing-state observation years

Explicitly dated ongoing states can display their observation year, including breastfeeding and chronic/ongoing symptoms. Later documentation of past or resolved events remains undated. This is a conservative wording-based compatibility formatter, not a fully semantic temporal model; future extraction should retain event/observation/documentation roles and uncertainty. All 35 template tests passed, including current versus previous/stopped breastfeeding and chronic symptoms.

### Founder build 205 — Group adjacent summary topics

App and PDF use a shared read-only presentation combining adjacent matching topic headings with semicolons. Source date labels must match; explicit temporal references and choices/status transitions remain separate. Original saved bullets and evidence remain unchanged. Split original bullets retain their matching date metadata. All 36 template tests passed, including adjacency, separate dates, and choices.

### Founder build 206 — Consistent care-plan grouping and dates

Complementary adjacent notes combine under shared headings across sections; conflicting statuses and temporal distinctions remain separate. Care Plan PDF dates are separate attributed runs in the description column, using the same 7.5-point grey style as other dates. Bullet continuation lines use a hanging indent toward the description, keeping wrapped dates with the note. Original data is unchanged. All 37 template tests passed and rendered care-plan and summary samples were visually checked.

### Founder build 207 — Fixed date column and shared topic labels

PDF topic sections now use Topic / Notes / Date columns, with small grey dates top-aligned in a fixed right column. Health History retains its left year column. Adjacent repeated topics have one label, even where distinct states or dates require separate rows. Compatible same-date notes combine despite explicit temporal wording; different historical years remain separate. The app hides repeated adjacent labels and retains per-note date lines. All 38 tests passed; four-page reference and focused date/status examples were rendered and visually reviewed. The reference gains a page because the notes column is narrower, with all content preserved.

### Founder build 208 — Quiet columns without new headers

Removed Topic / Notes / Date and Treatment / Notes / Date header rows and yellow bands from the newly column-aligned sections, including continuation pages. Retained column alignment, small grey dates, section titles, and existing History/Labs headers. All 38 template tests passed; rendered preview visually checked.

### Founder build 209 — Restore Clinical Snapshot stripe

Restored the red left accent alongside Clinical Snapshot column rows, including rows continued onto another page. Other styling remains unchanged. All 38 template tests passed and the rendered sample was visually checked.
