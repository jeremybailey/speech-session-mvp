# Whole-history B mainline

The normal cloud “My health story” flow on `codex/option-b-development` now uses B. The fallback remains `codex/pre-option-b-fallback-2026-11-02` at `9be4b9c18b76eede655bb94becf31282518becda`.

## Processing

One source-only whole-history request produces details, condition associations and care-plan occurrences. A second Luna medium writing request produces the compact overview (70–90 words targeted; 100 words maximum). No legacy extraction, checking, condition synthesis or care-plan classification is chained onto B. Explicit on-device processing retains its existing implementation.

Normal updating, reprocessing records, regenerating conditions and regenerating the overview use this pipeline. An overview-only regeneration reuses the existing B proposal when its originals still match. Systems rank by concern count descending, with stable ties.

B associations are proposals: exact source references/quotations are validated locally, and details enter the existing saved-story model as `sourceLinked`, with `reviewRequired` trust. Neither the overview writing pass nor reference validation establishes independent clinical verification. Patient edits, removals, preferences and original records are preserved. Publication is atomic across the full matching source snapshot; an original-record change rejects the commit. The first publication retains `pre-whole-history-sessions.json` locally and records per-record revisions.

## Recovery and authentication

The normal endpoint is `/api/v1/health-processing/whole-history`. It uses current Kinde authentication, normal owner isolation and the existing shared pilot ledger. No expiring diagnostic configuration is bundled. The historical experiment allowance and accounting remain untouched.

Each generation and writing request persists its identity before dispatch. Duplicate submissions reuse their reservation; interrupted polling resumes that job. Uncertain, incomplete, cancelled and invalid outcomes do not trigger automatic paid retry or splitting. Explicit Stop requests cancellation. A valid first pass can publish details, conditions and care plans even when the overview writer is rejected. The last valid overview remains displayed; its freshness is tracked separately. A rejected writer never publishes its narrative or starts an automatic paid retry.

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

## Overview rejection recovery

Only the overview is marked as needing attention when the first pass completed. The progress screen offers **Try overview again**, which uses the saved B proposal and runs only the writer. Rejected writer output and a specific validation reason are saved locally before remote payload cleanup, permitting diagnosis without another inference request. The original rejected response from the reported failure had already been discarded and could not be recovered.

The on-phone checkpoint replay recovered 156 details and 13 concerns across 11 records without API calls. Direct XCTest execution passed 427 tests with three existing skips, including private replay checks and strict number/reference/word-limit validation. The phone build passed. This recovery change needs no backend deployment.

## Duplicate presentation recovery

B source-occurrence IDs remain unchanged. Medication history now recognizes explicitly delimited fill/report descriptions and groups by the existing product identity (name, strength and form), displaying a concise product heading and keeping the complete original statements in the history. Unknown identities, brand/generic aliases, differing strengths/forms and conflicting patient decisions are not guessed away. Repeated exact B clinical statements also share a display card while retaining negation, qualifiers and event dates. Patient edits and explicit separation remain protected.

The saved checkpoint replay changed 64 medication occurrences into 17 displayed medication cards and 156 raw details into 109 displayed facts; all 156 unique source-occurrence IDs and all 13 concerns survived. Direct XCTest passed 432 tests, with three existing skips, including five duplicate regressions and the private replay. The device build passed. The change is local presentation only and requires no inference, regeneration, backend deployment or rewrite of saved clinical entries.

### Current-device verification (build 19)

The current phone checkpoint differed from the earlier replay: 57 medication occurrences rather than 64, and the model used “Medication record lists” in several descriptions. Report/record/history wording now shares the same bounded product parser. A local-only Debug diagnostic launch on the actual phone reported build 19, 11 records, 17 medication cards, 57 retained medication occurrences, and 111 total displayed facts. No inference or authentication request is made by that diagnostic path; the app was subsequently relaunched normally. The updated snapshot replay and 432 XCTest checks passed with three existing skips.

## Structured medication contract and presentation (build 20)

New B runs opt into `structured-medications-v2` within the existing whole-history request. Each medication carries separate source-selected name, strength, form, dose, frequency, route, duration, instructions, clinician, record date, record status and uncertainty fields. Non-medication rows use null. Older runs keep their original contract and request identities. The overview and durable server handoff accept both formats. No extra inference pass was added.

The app projects these values through the existing SummaryEntry field presentation and editor. Unsupported structured field values are omitted unless they literally match the row's original source passages. Cached narrative results use a bounded compatibility projection; original statements and quotes remain available in expandable source history. Raw metadata is no longer a heading or a practitioner. Current patient use stays unknown unless the patient sets it. Old active/prescribed record labels remain record history, not confirmation of current use. Empty dates are omitted and ambiguous numeric dates remain as written. Conflicting regimens are shown as varying across records, rather than selecting current directions.

Product reconciliation keeps brand/generic identity, strength and form boundaries; shared-unit combination-strength and eye-drop form notation group matching source products. Source occurrences, patient edits, explicit separation and conflicting choices remain preserved. The current phone snapshot replay produced 16 medication cards with all 57 occurrences, concise headings, no source-label practitioners and unknown current use. Tests passed: 440 native checks with three existing skips, and 125 backend checks with five existing skips. The build passed. Production deployment: `dpl_CTW3FTN2CYKfRzXXboQWdtHRKAnY` on the existing backend. No paid replay or budget changes were needed.

Actual-device verification confirmed build 20 with 16 medication cards, all 57 source occurrences, a maximum medication heading length of 44 characters, zero source-label practitioners and 16 unknown-current-use labels. The app was reopened normally after the local diagnostic check. An additional offline test using the actual app decoder passed for the new structured response, rejecting an unsupported field while retaining grounded fields and source attribution.

## Category and artifact formatting audit (build 21)

A's extraction populated separate titles, details, contact fields and action metadata. B retained complete source-linked statements, but its adapter bypassed several of those presentation paths. The build-20 medication repair did not cover contacts or the other categories. Build 21 restores local display projections; no prompt, model, request schema, output allowance, queue, reservation or backend route changes are involved. These changes add zero inference calls and zero generated tokens, and apply to saved results without reprocessing. This is not a new phone wall-clock benchmark.

| Category / artifact | Local repair |
| --- | --- |
| Care team & contacts | Person/organization name heading; separate labelled channels when stated in the same fact; role/history in body text. Multiple named people remain ambiguous, and a report signer's phone is not attached to an ordering clinician. Broad source passages are never mined for contact channels. |
| Tests & Labs | Explicit labelled values, plus existing numeric-result/reference syntax, become name/result/units/reference-range fields. Interpretations and report guidance stay intact; no abnormality inference, unit conversion or choice of latest result. |
| Vaccinations | Vaccine heading and recorded event metadata. A pharmacy fill remains a dispensing record, not evidence of administration. |
| Allergies, symptoms, chief complaints, findings | Labelled source values become fields when present. Long narratives become readable body text under a category heading; no shortening that discards negation, severity, laterality or uncertainty. |
| Context and other notes | Neutral attribution prefixes and internal metadata are separated from readable content. No new semantic categories or priorities are inferred. |
| Medications | Build-20 structured identity and event presentation retained; 16 cards / 57 source occurrences in replay. |
| Care plans and follow-up | Existing instruction/schedule/owner/consideration contract retained. Raw adapter metadata removed from supporting text and the editor; missing ownership stays unknown. |
| Condition pages, All, contact navigation and practitioner picker | Share the projected names/fields; no empty date rows or irrelevant contact body-area rows. Same-name navigation does not establish a saved identity; source histories and explicit separation remain intact. |
| PDF sharing | Uses the same projected entries and now includes unknown-status groups. Previously, its fixed status list omitted selected unknown-status facts entirely. |

All original entries, source quotations, relationships and verification state remain unchanged. Generated B content stays unverified. Patient edits and A entries retain their presentation behavior. Ambiguous identities are not guessed; one current replay contact requires review.

Validation: 449 native XCTest checks, three existing skips, zero failures, including an ignored private replay. The saved snapshot projects 110 cards from all 151 source occurrences, nine contact cards, and the same 16 medication cards / 57 medication source occurrences. Synthetic regressions cover multi-provider contact attribution, source-channel boundaries, labelled and numeric labs, vaccination fills versus administration, all 12 categories, patient edits, action semantics and export coverage. The phone build succeeded. No paid API calls or backend deployment were required.

Actual-device verification: build 21 installed and launched; nine contact cards use the new projected headings, medication counts remain 16 cards / 57 source occurrences, and all 110 facts remain visible. The local diagnostic also sees three untouched legacy field placeholders; the shared rendered-field filter excludes them, as covered by the private replay. The app was relaunched normally afterward. The diagnostic performs no inference or authentication requests.

## Restore content structure in the generation contract (build 22)

Build 21's category formatting was incomplete: it repaired headings and recognizable syntax but could not supply contact fields that B had omitted or left in prose. Build 22 adds opt-in `structured-artifacts-v3` to the same whole-history generation request. Sparse `f` pairs carry category-specific source-selected values for contacts, chief complaints, symptoms, findings, labs, allergies, vaccines, context and other notes. The medication `m` and action `p` contracts remain unchanged. Missing fields are omitted, not placeholders. Instructions replace prose field inventories with typed values and retain clinical qualifiers; this is not an extra extraction or formatting pass.

The app validates category field vocabulary, shape, size and duplicate keys, then retains only values literally matching its original primary/context passages after Unicode/case/whitespace normalization. New values populate editable SummaryEntry fields. The overview handoff receives the grounded fields under the same fact IDs, and the app's overview number check includes their values. Fields and exact source quotes remain source-linked, not independently verified. Per-person channel ownership is required by the prompt; literal grounding alone does not establish correct clinical attribution. Medication identities, care-plan ownership, unresolved charges and budgets are unchanged.

Old pending submissions keep their saved protocol flag and payload identity; old/v2/v3 responses all remain readable. No new endpoint, model call, paid retry, output allowance or processing stage was added. The schema and field syntax have some token overhead: an offline synthetic contact row measured 252 JSON bytes versus 211 bytes of older prose (41 bytes / 19.4% more for that fixture). That byte comparison is neither a token count nor a model latency benchmark. No paid timed replay was performed, so identical end-to-end runtime is not claimed. The original speed advantage from avoiding per-record calls is retained architecturally.

Saved B contacts also recover explicitly stated address/organization/role values from their own statements. For example, an explicit 'clinic address is …' becomes Address, and an adjacent named clinic becomes Organization. The original identifier boilerplate moves to source history once its meaningful fields have been recovered. Ambiguous printed rosters display Names listed and retain prescriber uncertainty without selecting an owner. Unknown aliases, specialties and channel ownership are not inferred; broad source excerpts are not mined for a person's contact channels.

Validation: 128 backend tests passed, five existing skips; typecheck passed. Native execution passed 454 tests with three existing skips, including a temporary harness exercising the actual app decoder/publication and malformed-field rejection. A separate private saved-snapshot replay passed 453 tests with three existing skips, retaining all 151 source occurrences and 110 cards, including 16 medication cards / 57 medication occurrences. Synthetic tests cover complete postal address and organization fields, unsupported field rejection, all structured categories, clinical qualifier retention, cached prose recovery and doctor rosters. Phone build succeeded.

Backend deployment `dpl_9XC2oHrqLNwxywgK7YG9XrTgMVqM` is READY on the existing production domain. Build 22 was installed and checked on the actual phone, then relaunched normally. Its nine source contact cards now expose two Organization fields, two Role or specialty fields, one Recorded involvement field, three Review fields and one Names listed field. The current saved B statements contain no recoverable Address/Phone fields; full original-to-field extraction needs the next explicit whole-history update. No automatic paid reprocessing was triggered as part of this task. The diagnostic report contains counts only.
