# Fork B resilience implementation — 6 November 2026

This is a tested implementation candidate, not evidence that the consumer release gates have passed. Work is in `codex/option-b-development`. Existing uncommitted audit and recovery work was preserved. The live pilot and installed phones were not changed. An isolated test project and empty database were created; four model calls used only synthetic data. No patient records were uploaded or altered.

## Implemented

- Shared native eligibility for health-story projections, counts, condition navigation, and PDF export. Generated medications require a grounded usable name; optional missing fields do not hide a named medication. Original records and patient edits remain stored. Rejected grounding values are retained internally.
- Patient-facing update status no longer describes billing decisions. Loading saved facts is independent of failure to produce a new publication.
- Versioned incremental extraction/verification contracts, generated Swift fact types, and compatibility with existing B results. The existing B overview has an opt-in visible-facts contract so withheld medication rows are not supplied as overview evidence.
- Durable PostgreSQL update/unit/attempt state, owner isolation, four-unit scheduling, atomic claims, idempotent publication, persisted Stop, webhook wakeups, uncertain-submission reconciliation, bounded retries, and source-revision checks.
- Extraction followed by independent verification. The checker can propose targeted repairs, but a third independent call must accept them. Repair work inherits the source unit's consumed attempt budget; three inference attempts total, including extraction, checking, repair checking, and transient replacements. Good facts survive a failed optional field or relationship. Invalid repair proposals cannot discard accepted base facts.
- Incremental native coordinator processes changed source hashes and publishes completed units progressively. Reopening retrieves the persisted job. Expired prepare receipts get one replacement per recovery invocation; already published facts remain. A current saved overview is reused.
- Overview generation and independent checking operate on the exact native published snapshot. Source IDs and numeric claims are checked deterministically; semantic checking is a separate model task. Failure leaves published facts intact.
- Transactional SQLite storage behind SessionStore, with verified JSON import, retained backup, transactional round-trip validation, incremental row writes, rollback, and rejection of unknown newer schema versions. Short-lived connections retain existing iOS file protection requirements.
- Build manifest containing source digest, commit, build, runtime feature flags, model, contract, validator, and migration versions; per-update release metadata; synthetic CI; fail-closed consumer release evidence checking.

- Persisted source assertion metadata and reconciliation outcomes: unchanged, corrected, recategorized, conflicting, unresolved, and patient-preserved. A unique unchanged source quotation and assertion signature survive shifted offsets without changing the saved occurrence ID. Ambiguous or contradictory assertions stay separate; omission never deletes a prior fact.
- Durable medication product IDs and a SQLite product table, separate from source events. Prescription, dispensing, and explicit patient-reported use remain distinct events. Strength/form differences produce different product identities. No brand/generic equivalence is inferred.
- Every-minute delayed-queue recovery sweep, with an authenticated daily cron reseed reschedules committed work after a missed enqueue, without app intervention. Retry backoff is persisted and duplicate deliveries cannot bypass it. Compatible saved independent-verifier output can be revalidated without another provider call; attempts, expiry, and cancellation remain intact.

## Validation performed

- Native package: **508 tests, 3 existing skips, 0 failures**, followed by six focused reconciliation/product tests after adding event-kind coverage.
- Saved private B response replay through actual decoder/projection: **49 medication source rows retained; 28 named rows eligible; 21 unusable rows withheld**. This measures presentation behavior, not clinically adjudicated recall. No clinical content was copied into test fixtures or logs.
- Full backend suite using seven fresh disposable PostgreSQL databases: **223 passed, 0 skipped**. The final repair-budget change additionally passed the focused **8-test** contract/database suite, including duplicate delivery, source isolation, concurrency cap, cancellation, uncertain submission, independently checked snapshot overview, and a three-call repair.
- TypeScript type checking, generated-contract drift check, and three release-evidence checker tests passed.
- iOS Simulator build and a signed physical-device build for `Whole-history B Phone` succeeded. The physical-device candidate uses the isolated backend. Xcode user-script sandboxing remains enabled. Manifest inputs are explicitly listed in `scripts/release-manifest-inputs.xcfilelist`.
- Local checks use synthetic provider responses except the offline saved-device replay. The isolated deployment additionally completed real-provider extraction, verification, overview generation, and independent overview checking on synthetic text. They do not measure fresh model accuracy, production queue behavior, or phone latency.

## Rollout configuration

`CC_INCREMENTAL_RECORDS_ENABLED` and `CC_SQLITE_ENABLED` default to **NO** in the Xcode project and expand into Info.plist. The signed device-test candidate explicitly uses incremental YES and SQLite NO. The immediate eligibility policy is not behind those gates. New server routes additionally require `AI_INCREMENTAL_RECORDS_ENABLED=true`, the existing durable pilot authorization, and `AI_QUEUE_ENABLED=true`.

Apply server migration 010 only in an explicitly selected environment using `MIGRATE_INCREMENTAL_RECORDS=1 npm run migrate:incremental`. Register the `health-record-updates` queue consumer from vercel.json. Use existing protected application database/receipt storage and TTL cleanup; do not extend provider retention. Enable incremental processing before enabling SQLite, consistent with the staged plan.

For release builds supply `CC_RELEASE_COMMIT` as an Xcode build setting containing the actual 40-character commit. Debug builds may record `unavailable-in-build-sandbox`; the consumer release checker rejects that value. Regenerate the input file list when adding manifest-covered source files. Run `scripts/release_manifest.py --build BUILD` outside Xcode to produce the full evaluation manifest, then `scripts/check_consumer_release.py EVIDENCE.json --manifest MANIFEST.json` to bind evidence to that source digest and build.

## Work still required before enabling the redesigned path broadly

1. Freeze and clinically adjudicate the real-record answer key. Measure supported precision and visible recall separately; withheld expected facts are misses. The saved replay is not an accuracy evaluation.
2. Validate reconciliation against the real archive. Unique unchanged quotations survive source movement; changed or ambiguous quotations are deliberately retained as separate/unresolved assertions. Broader semantic equivalence requires adjudicated evidence before permitting additional merging.
3. Validate compatible verifier replay in the deployed environment. The implemented allowlist permits v1 saved checker output to be revalidated under v2 without paid inference. Future incompatible contracts must not be included automatically.
4. Exercise all failure-injection cases against the deployed queue and real receipt adapter: worker termination at each transaction boundary, receipt-write failures, signed duplicate/out-of-order webhooks, expired provider results, authentication expiry, and source changes during app suspension. Local tests do not establish the five-minute completion target.
5. Verify SQLite migration on copied real archives, including full relationship/preference/history checks and rollback recovery. Medication products are stored separately from source occurrence/event rows; verify their relationships along with patient overrides.
6. Run actual phone rendering, lock/return, poor connectivity, large text, VoiceOver, recording/import, and recovery tests. Measure saved-history startup, median/p95 new-record latency, and eventual completion on at least 100 defined updates. No consumer performance claim is supported yet.

Do not enable or release the redesigned pipeline based solely on passing unit tests. Keep the last valid publication and the original JSON backup until migration and patient-outcome gates pass. The earlier audit remains useful context; its findings are not treated as instructions from the user.

## Device-test candidate and handoff

`scripts/build_resilience_device.py --derived-data /private/tmp/cc-resilience-device --base-url https://collectivecare-fork-b-recovery-test.vercel.app/api --build 56` prepares a signed iOS candidate using the existing development signing configuration. It never installs or deploys. `--sqlite` is a separate opt-in after incremental recovery has been tested. The candidate app is `/private/tmp/cc-resilience-device/Build/Products/Debug-iphoneos/SpeechSessionApp.app`.

The ordinary build default remains `https://speech-session-mvp.vercel.app/api`. Device-test build 56 explicitly uses `https://collectivecare-fork-b-recovery-test.vercel.app/api`. The test project is `collectivecare-fork-b-recovery-test`, backed by a newly created empty Neon free-plan database and project-scoped queues. It has a separate $1 processing ledger. The user added a temporary seven-day OpenAI key directly to the new project; the non-retrievable pilot key was not copied.

The isolated package uses one public API router and four private queue consumers to fit the existing hosting plan. It preserves Kinde authentication, raw upload/webhook bodies, and API paths. Tests reject public dispatch to queue consumers and malformed JSON. Static access to backend source/scripts/migrations is blocked before filesystem routing. Recovery uses a delayed queue heartbeat every minute plus a daily cron reseed; it does not require a Pro subscription.

Live readiness checks completed one synthetic extraction/verification unit and one synthetic overview/verification unit. The overview was inserted without its initial queue dispatch; the background heartbeat recovered it automatically. Total recorded model usage was $0.0005652, with zero outstanding reservations. This is an infrastructure smoke test, not a clinical quality or latency evaluation.

Once the selected test backend is ready and the signed candidate is installed:

1. Open the saved story: no blank loading screen and no nameless medication cards; original records remain accessible.
2. Add one small synthetic record: existing facts stay visible, new facts appear, and the overview updates only after those facts publish.
3. Lock the phone during processing, then return: the same update resumes without duplicate facts or a spending decision.
4. Disconnect/reconnect networking and repeat: automatic recovery should finish without restarting the history.
5. Stop an update, force-close and reopen: stopped work must not publish or restart.
6. Change a record during processing and edit a medication: stale results must not overwrite either change.
7. Try repeated fills, different strengths, and conflicting directions; inspect originals and source history for preserved distinctions.
8. Check large text, VoiceOver, recording/import access, and PDF export. Record perceived usefulness and measured timing separately from API success.

Do not use these checks as medical advice or as evidence that the precision/recall release targets have been reached. No patient-data inference has been run during implementation; only the four synthetic readiness calls incurred model usage.

Final isolation checks are recorded in `fork-b-isolated-readiness.json`. Both live pilot aliases retained their original deployment IDs. Anonymous API requests return 401; private queue endpoints and backend source/script/migration paths return 404. The signed build's embedded URL and flags were checked: build 56, isolated backend, incremental enabled, SQLite disabled. Build 56 was subsequently installed on the connected iPhone 16 Pro Max with user authorization. iOS confirmed its launch; visual phone UI verification remains pending.

Device handoff: build 56 installed in place and launched on 6 November 2026. No uninstall or explicit data deletion was performed. Synthetic-only inference statements above describe the pre-install readiness checks; subsequent device activity is not covered by those measurements.

## Build 57: condition organization regression

The corrected private archive (30BCBBEE) is an original build-18 export: 11 records, 92 projected facts, and nine saved synthesized concern groups across four health areas. It is not a post-build-56 device snapshot, so replay confirms the import path rather than every detail of the reported device state. No clinical content from the archive is committed or sent to inference.

Two build-56 defects were corrected: incremental mode bypassed valid saved condition synthesis, and new incremental results lacked body-system metadata, causing distinct named concerns to share the “Other health concerns” navigation heading. The app now preserves valid legacy organization; newly extracted condition-system assignments require independent verifier acceptance. Unknown-area named concerns are shown individually. Existing topic IDs and known areas are preserved. Old saved results lacking the optional field remain decodable.

Validation: 512 native tests executed, four skipped, zero failures, including private local archive replay; 225 backend tests, 218 passed, seven database-dependent skips, zero failures. Type checking, generated-contract checking, isolated router smoke, signed device compilation and signature verification passed. Database integration tests and new clinical inference were not rerun for this change.

The isolated backend deployment dpl_GnnD4iKbXaWyHWx7pYfA8qLbTBVK is ready. Anonymous API requests return 401; private queue and source paths return 404. Both original pilot alias deployment IDs remain unchanged. Build 57 was installed in place and launched on the connected iPhone 16 Pro Max on 6 November 2026. SQLite remains disabled. Actual phone rendering and patient-quality acceptance remain to be checked by the user. Opening the saved story is the first check; this presentation fix does not require a full-history regeneration.

## Build 58: isolated mild tiredness stays in All

Presentation-only guard in ConditionSummaryProjection.isNavigationEligible, applied to the health story navigation groups. Automatically organized tiredness/fatigue groups consisting only of symptom entries from at most one source, whose excerpts explicitly describe mild symptoms without ongoing/recurring language, remain in All instead of receiving a Conditions card. Duplicate versions of one source do not qualify as longitudinal evidence. Explicit patient topic choices, non-symptom evidence, multiple sources, ongoing language, and missing/unclear evidence retain existing behavior. This is deliberately a narrow presentation exception, not a comprehensive clinical condition classifier.

No extraction/verification prompts, provider calls, recovery state, backend deployment, stored grouping, facts, original records, patient edits, or overview inputs change. Initial broader symptom-only filters failed the private replay because they removed back-pain groups; those candidates were not installed. The final replay requires exactly eight of the nine existing groups, retaining the eye, cardiovascular, and movement areas and all 92 facts.

Build 58 validation: 15 focused native tests passed, including the private archive replay (eight visible groups, 92 retained facts). Signed iOS build and signature verification passed. Installed in place and launched on the connected phone on 6 November 2026; visual confirmation remains pending. No backend deployment or inference was performed.
