# Care Story Lab implementation checkpoint — 2026-11-07

Branch: `codex/editable-health-story`, based on Fork B `8fd59ba`.
This is an experimental implementation in progress, not a release candidate.

## Isolation

- Native identity: `com.CollectiveCare.storylab`; app group `group.com.CollectiveCare.storylab`.
- Display name: Care Story Lab. Separate app and extension containers.
- Backend project: `collectivecare-story-lab`. Separate free Neon resource provisioned.
- No pilot backend changes, patient import, live inference, or experimental distribution performed.
- Dedicated OpenAI credential, approved processing ceiling, and separate Kinde native client remain setup dependencies. The checked-in public Kinde client ID is still a placeholder inherited from the pilot; do not distribute before replacing it.

## Implemented

- Overview / Records / Details navigation with persisted last tab.
- Editable story paragraphs, local persistence, two-second reconciliation debounce, attributed correction records, revision checks, presentation-only deletion, and Undo.
- Correction citations point to the patient correction record rather than the original report.
- Original source text and revision history retained. Record drafts save locally; explicit Save corrected text commits a source revision and requests existing processing.
- Source passage removal retires matching generated occurrences; patient-written occurrences remain intact. Restoring text cannot revive an assertion superseded by an active patient correction.
- Care adoption, pause/stop status, dated progress records, recurring occurrence logging, and dismissible daily in-app check-in.
- Persisted conversation, explicit Save to records, evidence snapshots, idempotent answer publication, and local cancellation guards against late results.
- SQLite storage for story sources, blocks, edits, care events, messages; latest-revision FTS lookup; archive relationship validation.
- Versioned story-operation backend with idempotency, existing durable ledger integration, separate verification inference, typed result validation, cancellation endpoint, and seven-day request-text retention ceiling.
- DEBUG-only synthetic-data simulator launch (`--storylab-fixture`) for the isolated bundle; normal builds retain sign-in.

## Verified so far

- Simulator build succeeds; Overview rendered with synthetic data and three tabs.
- Full Swift run: 522 tests, 5 skipped, zero failures.
- Backend typecheck succeeds; 225 tests passed, 7 database-dependent tests skipped.
- Focused persistence scenarios include deletion vs clinical truth, coalesced typing/stale edits, correction Undo, source revisions, idempotent chat saving, recurring progress, cancelled late answers, offline draft persistence, and correction source attribution.
- These tests do not establish semantic accuracy or physical-device performance.

## Remaining implementation and release gates

1. Complete typed assertion/evidence supersession rather than treating all new patient corrections as general notes. Validate preservation across subsequent source regeneration and independent supporting sources.
2. Complete targeted narrative refresh, patient focus/preferences, editable plan/progress prose, and exact per-claim source navigation. Current generated paragraph refresh consumes existing overview output.
3. Complete automatic record-edit reconciliation after inactivity/Done. Current record editor saves drafts immediately but commits via Save corrected text.
4. Wire durable Stop and retry controls through the native UI and server. The verifier starts on the next client poll; fully unattended chaining remains to be implemented and failure-injected.
5. Add completeness-sensitive structured query responses with explicit completeness metadata; bound retrieval without silently losing expected facts. Current FTS is a source candidate filter with in-memory fact ranking.
6. Complete selected-record import UI, untouched import backup verification, export/Undo round trips, independent-source retirement, source-edit-during-inference, and stale condition membership tests.
7. Apply migrations to the isolated database, configure auth/budget/keys, deploy only the separate backend, verify access controls and active-deployment guard, and run DB integration tests.
8. Frozen semantic evaluation, physical-device import/edit/recovery, VoiceOver/large text, keyboard, interrupted recording, and latency measurements remain outstanding.
9. No TestFlight distribution until those gates pass and a selected tester list is established.

Do not interpret green unit tests as permission to distribute this checkpoint.
