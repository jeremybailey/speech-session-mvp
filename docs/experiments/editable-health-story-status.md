# Care Story Lab — implementation and verification, 2026-11-07

Branch: `codex/editable-health-story`, based on stabilized Fork B `8fd59ba`.
The experimental implementation is available for private validation. It is not approved for tester distribution.

## Isolated environment

- App: **Care Story Lab**, `com.CollectiveCare.storylab`, with separate app/extension containers and `group.com.CollectiveCare.storylab`.
- Backend: https://collectivecare-story-lab.vercel.app
- Active deployment: `dpl_DN2JV9hRT9Q2H5gNMjKfAyqaNgCL`.
- Separate Neon database, migrations 001–012, separate API key and fresh backend secrets.
- Shared budget `storylab-v1`: **$10 total**, $0 used/reserved at deployment verification. Production readiness enforces the $10 ceiling. Legacy unbudgeted chat/audio endpoints reject durable-mode callers.
- Existing Kinde client and tenant retained for account continuity. Additional callbacks must be registered: `comcollectivecarestorylabkinde://kinde_callback` and `comcollectivecarestorylabkinde://kinde_logoutcallback`. Pilot URLs must remain registered.
- No pilot app/backend changes, patient-data inference, or TestFlight distribution performed.

## Implemented behavior

- Overview, Records, Details tabs; persisted last tab.
- Editable story, plan and progress prose; immediate local writing persistence; two-second reconciliation debounce; revision guards; presentation-only deletion; attributed patient correction records and Undo.
- Explicit patient-written care-status changes are typed, independently checked, and restricted to supplied care-plan facts. Recommendations remain intact. Undo refuses to overwrite newer status changes.
- Changed source records use the existing incremental extractor. Patient corrections remain attributed to their own revision history, with existing source statements retained. Undone corrections cannot re-enter extraction or retrieval.
- Direct source navigation for each supporting occurrence/revision. Patient-authored prose is protected during generated-overview updates.
- Record drafts survive relaunch; inactivity or Done commits a source revision and requests processing. Original text/assets and revision history remain accessible.
- Selected-record import verifies archive hashes and relationships before atomic replacement in the experimental container, retaining an untouched encrypted ZIP backup. Partial imports copy selected records and corrections, not the old cross-history story/chat.
- Recorded recommendations are separate from adopted plans. Adoption, pause, stop, dated progress, recurring occurrence logging, explicit check-in focus, daily dismissal and disabling are persisted. No new notifications.
- Explicit Ask/Add composer; persistent conversation; chat saves only on explicit Save to records. Add and progress submissions do not ask a second saving confirmation. Progress submissions are idempotent.
- SQLite story storage and latest-source full-text search. Complete medication/current-plan queries use structured facts with explicit scope/truncation metadata. Ordinary retrieval never claims complete coverage.
- Durable backend operation identity, independent checking without phone polling, Stop-before-submit tombstones, active-deployment fence, 30-second transient retry backoff, 15-minute ambiguous reconciliation, and a maximum of three inference attempts including verification. Existing unresolved accounting stays reserved.
- Stop persists locally and reaches the server after reconnection; stale/cancelled results cannot publish locally. Server request text is purged after seven days even if inference is disabled.

## Verification

- Simulator builds pass and the three-tab app has been rendered with synthetic data.
- Latest full Swift suite: **527 tests, 5 skipped, zero failures**; later focused source/Undo checks also pass.
- Backend: **234 tests passed, no skips**, including all PostgreSQL integration suites against independent temporary local databases and mocked inference.
- Integration coverage includes single verification creation under concurrency, retry backoff/caps, cancellation, retention, budget accounting, source isolation, worker/provider receipt recovery, import integrity and idempotent publication.
- Native regressions cover source removal with independent support, narrative deletion, stale edits, correction citations, Undo, explicit plan adoption, recurring progress, duplicate progress saves, offline drafts and selected imports retaining their original archive.
- Deployed API rejects anonymous access (401); private source paths return 404.

## Required before distribution

1. **Device installation completed November 8:** refreshed Xcode credentials successfully provisioned and signed the separate app. Care Story Lab was installed and launched on the connected iPhone alongside the pilot.
2. User confirmed both Kinde callback URLs were registered November 8. An actual device sign-in still needs to be verified.
3. Run a physical-device import/edit/Undo/recovery session and actual-model semantic evaluation with the approved budget. No real inference has been exercised in this experiment yet.
4. Verify VoiceOver, large text, keyboard/focus behavior, interrupted recording, locked-phone return and measured latency. Automated tests are not substitutes for these checks.
5. The current narrative refresh reuses the established overview generator and protects patient blocks during projection. A fully independent per-block refresh scheduler and exhaustive semantic coverage for ambiguous edits remain follow-up work; do not claim the full target architecture or accuracy/latency gates are complete.
6. Distribute only after these gates pass and the selected experimental tester list is established. Do not update the existing pilot distribution.

## November 9 onboarding repair

Non-Apple device sign-in reached onboarding, which failed to load the agreement. Production environment inspection confirmed PILOT_AGREEMENT_VERSION was absent from the isolated setup. Enabled the existing approved version 2026-10-19.1 and deployed the backend with a new production gate requiring that exact published version and the agreement acceptance table. Activated the new deployment in the worker guard. TypeScript and both agreement contract tests passed; production build readiness passed; anonymous agreement GET returns 401. Authenticated phone retry remains to be verified. No agreement wording, pilot deployment, Apple credentials, or patient acceptance records were changed.

## November 9 Settings navigation repair

Details inherited an empty default Settings callback. Connected that action to Records’ existing Settings sheet, and added direct Settings access in Overview Options and the Records toolbar. The existing recording/import/processing transfer gates and confirmation flow remain in use. Signed device build 62 passed compilation and bundle/backend checks and was installed in place on the connected iPhone. git diff --check passed. Actual tap-through and sample ZIP import still need device confirmation.

## November 9 ZIP import investigation

User reports archives/passwords accepted by the pilot fail on Story Lab. Replayed the previously supplied archive locally through prepareDataImport successfully before and after changes. No crypto-library or streaming-adapter difference from baseline was found. Original phone cause remains unconfirmed. Import now coordinates a read from Files into a protected, hash-verified local backup before extraction; preserves cancellation; distinguishes minizip password-verifier rejection (-108) from streaming/integrity errors; disables password-field capitalization and autocorrection. Sixteen transfer tests plus the optional local archive replay passed. Signed device build 63 succeeded. Actual affected-archive phone retry remains required. No data was sent for model inference.

## Settings consolidation

User confirmed ZIP import succeeded; the original password failure cause remains unproven. Removed duplicate Settings entries from Overview and Details, retaining one entry at Records → gear → Settings and its existing transfer safeguards. Removed the cross-tab presentation request introduced in build 62. Prepared device build 64 for the next update; do not interrupt an active import to install it.

## 2026-11-09 — simple narrative and chat, build 65

Overview now reads the existing Fork B whole-history overview instead of presenting fallback fact-title blocks. One editable document replaces the care/check-in/edit prompts. Typing saves presentation text locally without reconciling structured facts; existing structured-edit queue processing is paused. Records retains the sole Settings entry. Chat is in a medium/large drawer, includes prior conversation, and retrieves local evidence with bounded context. SQL remains authoritative; no hosted vector-store uploads were added.

The observed unanswered chat had completed inference but included an unknown citation ID; strict pre-check validation prevented the independent checker from starting. Candidate parsing now permits checker repair, while final publication still requires valid references. New chat requests constrain citation IDs to supplied evidence IDs and stream actual Responses text into transient draft storage; the app polls at one second and labels drafts until verification completes.

Validation: signed device build 65 succeeded; 13 StoryWorkspace tests passed; 6 story-contract/stream parser tests passed; full backend suite 228 passed, 8 skipped; isolated synthetic PostgreSQL test passed, including unknown candidate citation repaired through the actual runtime, duplicate checking, cancellation, bounded retries and expiry. Phone latency, appearance and real-data answer quality remain to be checked.

Isolated deployment: dpl_9QgmNU8Tk6dGtw5oR8uAbmRHHTug, production alias collectivecare-story-lab.vercel.app, active-deployment guard updated. Existing pilot unchanged. Current implementation uses retrieved evidence with Responses and independent checking; it is not yet a general tool-calling agent.

## 2026-11-09 — navigation and Records refinement, build 66

Overview editing has focus-controlled Done actions in the navigation bar and keyboard accessory, plus interactive scroll dismissal. The chat launcher hides while the overview is focused. Records uses native month sections, newest-added first, compact title/date rows and a meaningful empty state; it no longer repeats transcript previews. Details omits the redundant original-record list but retains individual evidence links. The chat launcher uses the existing iOS 26 Liquid Glass modifier with material fallback. No backend or clinical-data changes are needed for these interface changes.

Ongoing UX constraints: follow Apple HIG and system navigation/keyboard/accessibility conventions; reserve Liquid Glass for controls, keep text surfaces readable, and use semantic colors and text styles. Apply NN/g principles of visible state, clear exits, consistency, recognition, error recovery and minimal clutter when adding features. Granola is a scanning/layout reference, not a replacement for native iOS behavior. References: https://developer.apple.com/design/human-interface-guidelines/keyboards and https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views and https://www.nngroup.com/articles/ten-usability-heuristics/.

## 2026-11-09 — combined Records and Overview, build 67

Two tabs now: Records (read-only Overview above the month-grouped timeline) and Details. Existing overview text and writing are preserved. Bottom controls combine Ask anything with a blue Add record button; recording/import status controls still replace idle controls while working. Refresh overview is in the Records options menu.

Chat opens with a clean greeting/composer and displays new exchanges for that opening. A separate history sheet, available top right, restores a selected previous exchange. The persisted conversation and model context remain intact. Inline source quotations are replaced with tappable source tags leading to original records; evidence without a linked record opens a quotation view. Native close/dismiss, keyboard Done, scrolling, and dynamic text styles retained.

Signed device and simulator builds passed, git diff check passed. Simulator UI automation was unavailable; interactive visual/device verification remains outstanding. No backend change or new inference was needed.

## 2026-11-09 — chat polish and original record navigation, build 68

Bracketed evidence IDs in finalized chat answers render as small inline Record links at the citation position, resolving only against that answer's saved evidence. Unresolved identifiers are not exposed or guessed; streamed draft citations are suppressed until checked evidence is available. Source tags still provide access to evidence supplied without an inline marker.

Chat greeting and composer now share 20-point margins; greeting fills the available width, input begins at one line and grows, and keyboard Done is removed in favor of drawer close/scroll dismissal. Record icons derive from original asset type (photo, PDF, scan, audio, text), falling back to the capture type for legacy records. Timeline rows open the existing SessionDetailView at Text/Transcript, retaining the Summary / Original / Text segmented control. No storage or backend changes.

## 2026-11-09 — Records citation popover, build 69

Inline chat citations now display a small link symbol and Records label. Each bracketed citation group renders one link. Single-source answers open the saved source directly; multiple-source answers open a compact popover anchored to the answer with the same full-label source tags available below the answer. Selecting a tag opens the source sheet. Compact-width presentation retains a popover, and the source list scrolls for long labels or many records. Signed build and diff checks passed; device interaction still needs checking.

## 2026-11-09 — readable inline citation links, build 70

Records links now use a minimum 20-point font with Dynamic Type scaling. Nonbreaking spaces join the link symbol and Records label so the tag wraps as one unit instead of splitting over two lines. Existing source/popover routing remains unchanged.

## 2026-11-09 — unified source-tag styling, build 71

Inline citations and full-label source tags now share SF Symbol link icons (no emoji), blue foreground, tertiary system-fill rounded capsule background, 20-point minimum text with Dynamic Type, and matching padding. Inline tags use native UITextView linked text attachments to keep the rounded shape and symbol together within wrapping prose, with at least 44-point height. Source navigation and multi-source popovers remain unchanged. Chat answers, question text, prompt and history titles are enlarged; history dates and checking status use body text. Device build and diff checks passed; visual, tapping and assistive-technology behavior still require device verification.

## 2026-11-09 — inline popover anchor fix, build 72

The source popover previously used the full answer view as its anchor, which placed it near the bottom of long answers. The UITextView link callback now passes the tapped attachment's text rectangle to SwiftUI's popover attachment anchor. Popover height is bounded using available space above/below the tag, and its source list starts at the top and scrolls. Keyboard focus is dismissed when opening a source. This addresses geometry, without changing evidence or processing. Physical-device placement remains to be verified.

## 2026-11-09 — single primary screen, build 73

Removed Story Lab's tab bar. Records with its Overview is the root of one NavigationStack; a labeled Details button in the top toolbar pushes the existing structured-data screen with standard Back navigation. Settings and story options stay in the top toolbar. Ask anything and blue Add record remain the sole persistent bottom control row. Returning to the root refreshes the displayed data. Existing recording/import status controls and chat drawer are retained. This is a presentation/navigation change only; pilot UI, backend, records and saved conversations are unchanged.

## 2026-11-09 — Profile on Records, build 74

Details navigation now uses the square.grid.2x2 SF Symbol with a Details accessibility label. Records owns the Profile menu with account status, Settings and sign-in/out. The separate Settings toolbar icon is removed. In the experimental Details screen, account controls are removed and the remaining processing actions use an ellipsis labeled Details options. Existing pilot profile behavior is preserved.

## 2026-11-09 — main screen title, build 75

Renamed the experimental root screen from Records to My health story, reflecting the combined overview and record timeline.

## 2026-11-09 — Profile refresh action, build 76

Moved Refresh overview into Profile and removed the separate Story options toolbar menu. The root toolbar now contains Details and Profile.

## Build 78 — simple grounded plan

Added Story / Plan segmented navigation. The read-only plan uses existing HealthCarePlan projections and explicit patient adoption/status; fictional plans are excluded. Current actions retain source wording, timing and qualifiers, with source links. Other recommendations are separate and collapsed; no inferred due dates, new logging, reminders, or model calls. Physical-device visual verification remains pending.

## Build 79 — care plan navigation

Replaced the Story / Plan switch with a native My care plan navigation row immediately below the overview. An SF Symbol and native chevron open a dedicated page with standard Back navigation. Grounded plan content and adoption rules are unchanged.

## Build 80 — restore care-plan actions and context

Restored encounter-level plan titles, dates, practitioner and condition context, with Actions / Follow-up / Considerations grouping. Render full saved timing, context and owner fields rather than the compact metadata projection. Recorded recommendations start expanded so existing plans are visible. Source links and explicit adoption rules remain unchanged; no inference or storage mutation.

## Build 81 — care-plan hierarchy

Removed per-action extraction/verification metadata from this presentation; source links remain. Replaced nested grouped containers with a flat, readable document layout: section label, prominent plan title, quiet attribution, action headings and full timing/context. Recommendation links use rounded SF Symbol tags with 44-point targets. Status and conditional wording remain, underlying verification data is unchanged. Uses Dynamic Type and standard navigation, with glass reserved for system controls rather than content.

## Build 82 — chat history colors

History rows now use plain buttons and explicit semantic primary/secondary text colors, preventing inherited blue button tint. Plain list with transparent rows over a system background removes the gray grouped-list panel. Compact navigation title and accessible close control retain the native drawer.

## Build 83 — chat session visibility and numbered citations

Replaced snapshot-based hidden message IDs with explicit visible question/answer IDs using the persisted deterministic reply identity. Opening chat starts empty; history restores the selected pair; delayed completions from older sessions stay in history. Guard queued callbacks by drawer session identity and only show streaming output for a selected question. Inline citations now render as numbered atomic circles, numbered by first appearance per answer; each opens its exact source. Full source labels remain below answers. No persistence or backend changes. Device checks: close/reopen during inference, select history during completion, repeated/grouped citations, light/dark and Dynamic Type.

## Build 84 — chat composer backdrop

Added a 32-point transparent-to-solid fade above the composer, with an opaque system background behind it and through the bottom container safe area. The backdrop adapts to dark mode, does not intercept touches, and leaves keyboard safe-area handling intact.

## Build 85 — long-chat navigation

Softened composer fade over 64 points. Added a 44-point circular down-arrow above the composer only when the end marker is below the scroll viewport. Tapping scrolls to the latest content and respects Reduce Motion. Incoming saved messages no longer force-scroll while reading earlier text. Keyboard and Dynamic Type changes update viewport geometry. Device visual checks remain pending.

## Build 86 — chat typography and patient bubbles

Adjusted chat base text from 20 to 18 points with Dynamic Type scaling, added proportional line/paragraph spacing to native answers and streaming drafts, and introduced right-aligned patient questions with a subtle semantic fill and rounded corners. Composer, history and source tags use the same base scale. No conversation or clinical-data changes.

## Build 87 — template-based sharing

Added a share icon next to Overview and a practitioner-template screen based on the supplied fictional summary’s seven sections. Generates a single text document from the complete eligible saved-fact snapshot, without chat-history evidence or item toggles. Uses the existing story operation and independent verification; no backend deployment. Keeps a persistent separate summary, request receipt and evidence references; cancellation prevents publication. Rejects oversized evidence instead of silently truncating. PDF export uses shared Core Text pagination, preview and explicit system sharing. Patient template/overview integration remain future work. Four regression tests cover coverage beyond 100 facts, section contract, saved summary/cancellation, and long PDF pagination. Synthetic PDF visually inspected; no real patient inference run during implementation.

### Build 88 — large-history template summaries

- Replaced the whole-snapshot 80,000-character rejection with bounded, encoded-size-aware batches (70,000 text characters / 120,000 encoded bytes / 100 evidence items per request). Every eligible snapshot item enters a batch; no ranked prefix is used.
- Removes processing/identity metadata from summary input while retaining clinical evidence, source excerpts, medication details, care instructions, attribution and status.
- Each batch uses the existing independently checked story operation. Large histories receive a checked consolidation pass over partial summaries; this is a selective summary, not exhaustive extraction. Original evidence links survive consolidation.
- Freeze each attempt's input and persist deterministic child operations and checked results. Retry/relaunch reuses completed children. Parent cancellation cancels queued children and prevents late publication. A prior valid shared summary stays available throughout.
- Verification: 19 focused template/workspace tests, including oversized Unicode/quoted evidence coverage, bounded payloads, stage persistence and cancellation; signed iPhone build succeeded. Live patient-data generation and visual review of this change remain device checks, not claimed as automated validation.

### Build 89 — practitioner summary hierarchy and tables

- Reference-inspired subheadings for priorities, responsibilities, appointment context, medications, supplements, lifestyle, prior treatments and investigations. Supported chronology, intervention and result rows use Markdown tables in the stored single document.
- Shared block parser renders legacy paragraphs, section headings, subheadings and 2–4 column tables. Phone preview supports horizontal table scrolling with readable type and labeled accessibility cells.
- PDF uses wrapped, selectable table text, shaded headers, fine row separators, repeated continuation headers and cell continuation for exceptionally long rows. Heading pagination accounts for following content.
- Nine focused summary tests passed, including malformed-table preservation, long rows, repeated headers and existing batching/cancellation checks. Signed build succeeded; two-page synthetic PDF visually inspected. No live patient-data generation was run; regenerate saved summaries to use the expanded formatting prompt. Existing data and summaries remain readable.

### Build 90 — PDF presentation and quieter summary screen

- Replaces boolean-sheet/optional-URL presentation with an item-driven sheet holding a preloaded, validated PDFDocument and file URL. Native PDFKit canvas renders it with explicit Close and Share PDF controls.
- Preview PDF is in the fixed top toolbar. Regenerate is in Summary options. Removes template explanation, prepared timestamp and introductory copy before Clinical Snapshot.
- Adds an editable, persisted patient name to the summary header and PDF. Generation may supply a name only when evidence explicitly identifies the patient; account/document-title guesses are prohibited. Older summaries decode without a name and can have one entered without regeneration.
- Verification: signed build succeeded; 23 focused tests passed; two-page named synthetic PDF visually inspected. Actual first-tap preview on the phone remains a device check.
