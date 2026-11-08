# Care Story Lab — implementation and verification, 2026-11-07

Branch: `codex/editable-health-story`, based on stabilized Fork B `8fd59ba`.
The experimental implementation is available for private validation. It is not approved for tester distribution.

## Isolated environment

- App: **Care Story Lab**, `com.CollectiveCare.storylab`, with separate app/extension containers and `group.com.CollectiveCare.storylab`.
- Backend: https://collectivecare-story-lab.vercel.app
- Active deployment: `dpl_9PpFkQQsWwFPyMcMNW5CCfe1LeCL`.
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
