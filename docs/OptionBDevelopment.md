# Whole-history B mainline

The normal cloud “My health story” flow on `codex/option-b-development` now uses B. The fallback remains `codex/pre-option-b-fallback-2026-11-02` at `9be4b9c18b76eede655bb94becf31282518becda`.

## Processing

One source-only whole-history request produces details, condition associations and care-plan occurrences. A second Luna medium writing request produces the compact overview (70–90 words targeted; 100 words maximum). No legacy extraction, checking, condition synthesis or care-plan classification is chained onto B. Explicit on-device processing retains its existing implementation.

Normal updating, reprocessing records, regenerating conditions and regenerating the overview use this pipeline. An overview-only regeneration reuses the existing B proposal when its originals still match. Systems rank by concern count descending, with stable ties.

B associations are proposals: exact source references/quotations are validated locally, and details enter the existing saved-story model as `sourceLinked`, with `reviewRequired` trust. Neither the overview writing pass nor reference validation establishes independent clinical verification. Patient edits, removals, preferences and original records are preserved. Publication is atomic across the full matching source snapshot; an original-record change rejects the commit. The first publication retains `pre-whole-history-sessions.json` locally and records per-record revisions.

## Recovery and authentication

The normal endpoint is `/api/v1/health-processing/whole-history`. It uses current Kinde authentication, normal owner isolation and the existing shared pilot ledger. No expiring diagnostic configuration is bundled. The historical experiment allowance and accounting remain untouched.

Each generation and writing request persists its identity before dispatch. Duplicate submissions reuse their reservation; interrupted polling resumes that job. Uncertain, incomplete, cancelled and invalid outcomes do not trigger automatic paid retry or splitting. Explicit Stop requests cancellation. The prior saved story remains until both passes validate and publish.

A complete on-phone trial result can be migrated without another model call only when its originals match all current ready records. Private processing state is saved under `whole-history/preview.json`, excluded from backup. Old diagnostic connections are removed after successful publication.

## Build

Open `SpeechSessionApp.xcodeproj` in this checkout and choose `Whole-history B Phone` and your phone. The normal home screen shows the result; there is no Experiments entry to use. The existing bundle ID is retained so installation preserves app data.

The historical frozen harness/contracts under `scripts/whole_history_aggregation` remain for reproducibility. Active backend source is in `vercel-openai-proxy/api/_lib/whole-history-*` and `api/v1/health-processing/whole-history.ts`.

## Validation and limitations

The final package suite passed 424 tests with three existing skips. Four new persistence tests cover source changes, missing quotations, exclusions, edit preservation and source-linked trust. Backend checks passed 115 tests with five existing skips. A replay through the actual native converter retained every fact and concern in all five frozen cases. The device Debug build passes.

Production deployment `dpl_7pnBzmnmGgqMkoXUkTLKZxMzaHuf` is ready on the existing `speech-session-mvp.vercel.app` backend. The existing additive receipt migration (008) was applied; the shared budget readiness check passed. An anonymous request to the B route returns 401. No paid replay was needed for this integration.

For local replay, run `python3 scripts/replay_whole_history_native.py --fixtures /private/path/to/frozen-cases`. The private folder must contain the five original `*/native-cache.json` fixtures; fixtures are never committed. The helper removes its generated test afterward.

Earlier compact-overview evaluation covered one cached patient result and four synthetic histories. These checks do not establish population-level clinical accuracy. This development mainline is not an App Store release.

## Phone locking and background continuation

New whole-history updates request server-managed continuation. Once the source upload is admitted, the existing private processing queue runs generation, reserves one deterministic overview child, and dispatches that child without a phone-side handoff. The app retains both identities and collects/publishes the results when active again. Overview-only requests are also queued immediately. Existing interrupted runs retain their earlier request protocol to avoid changing their deduplication identity.

Stop prevents a queued overview or cancels it if already queued; an already dispatched provider call may still settle. Queue redelivery reuses the durable child. Failed, incomplete, uncertain and malformed outcomes never create an automatic paid retry. Untargeted maintenance excludes these longer B jobs so the private queue owns their dispatch.

The background change passed 123 backend tests with five existing skips, including simulated phone absence, duplicate delivery, failed child publication, cancellation, uncertain generation and malformed output. The device build passes. A physical locked-phone end-to-end run remains a device validation step; these tests make no phone timing claim.

Background continuation deployment: `dpl_FnaoHy48SETLdiSHXVGvxTrP1MUV`, using the existing private `health-processing-jobs` consumer with a 300-second bound. Deployment is READY on the existing production domain. No account-plan change, budget reset or paid test inference was required.
