# Founder-equivalent pilot candidate

Prepared on `codex/pilot-founder-parity` from founder release `ee76e47` (app source `064ab54`, build 222). Candidate app build: 223.

## Scope

The implementation is the founder code wholesale. Pilot identity is retained: `com.CollectiveCare.pilot`, its extension bundle IDs, app group, authentication callbacks, display name and `collectivecare` URL scheme. The backend address remains `https://collectivecare-fork-b-recovery-test.vercel.app/api`. Pilot launch/update presentation and its light/dark release gates are retained alongside founder loading animations.

`Sources` and `vercel-openai-proxy` are byte-for-byte unchanged from the founder baseline. No clinical data, credentials, budget values or database contents were copied. The release manifest default backend is corrected to the pilot address.

## Checks completed

- Generic iOS Debug candidate build succeeded with signing disabled; not installed or uploaded.
- 38 selected tests passed: SQLite storage, story workspace and data transfer. These are automated regression checks, not an actual installed-pilot upgrade test.
- Three release-gate unit tests passed.
- Pilot entitlements, authentication file, URL schemes and display name checked against `origin/codex/pilot-production`.
- Diff whitespace check passed.
- Service package staged locally at `/tmp/cc-pilot-founder-parity-service`, including migration 013 and the founder queue/cron configuration. No deployment was made.

## Before activation

Follow `PilotPromotion-2026-11-22.md`. Inspect actual pilot environment and migration state; verify queue delivery, recovery, receipt cleanup and existing-client compatibility. Decide and validate promotion of the founder-only accelerated execution policy rather than bypassing its release guard. Preserve pilot budgets and accounts. Then test the signed candidate as an in-place upgrade over existing pilot data, verify Light/Dark launch controls and PDF flows, and distribute narrowly before wider promotion.

This candidate is reviewable source and a compiled app, not evidence of live pilot readiness. The existing pilot branch, app installation, backend, database and tester distribution remain unchanged.

## Readiness continuation

- Signed Release archive and signed Debug device build 223 succeeded. Archive identity, source digest and pilot backend URL verified against `ebdf07b`.
- All **293** backend tests passed, zero skipped, after running the database tests in separate local PostgreSQL databases containing fictional data. That local server was stopped afterward.
- Read-only live pilot check: existing durable ledger, story and agreement tables present; summary workflow tables absent. Existing allowance $10, used $1.0262271 and reserved $0 before the fictional provider check. No budget increase or account copying performed.
- Applied additive migration 013 through an inactive deployment. Enabled-workflow production readiness subsequently passed on staged release `dpl_CCcvo8SqFVLS1af79F8VY87WX55t` at `https://collectivecare-fork-b-recovery-test-5uediywg4.vercel.app`. It has **not** been promoted or activated in the worker fence.
- Candidate settings enable record, practitioner and overview workflows, use the baseline execution policy (parallel and low-merge flags false), retain pilot budget/credentials, and bind backend source metadata to the candidate. Flags were passed to this deployment; project-wide activation settings remain a rollout step.
- Candidate endpoint check returned 401 without patient authentication; private server source returned 404 after platform-protection bypass.
- A temporary build-only preflight used a fixed fictional knee/physiotherapy example with the pilot provider. It completed 3/3 steps with 3 calls; acknowledgment left zero parent payloads, child payloads and step outputs. This establishes provider/receipt processing, not runtime queue or cron delivery. Temporary diagnostic deployments were removed.
- User explicitly approved private temporary backups of Documents and Application Support at `/tmp/cc-pilot-upgrade-baseline`, solely for upgrade preservation verification and deletion afterward. Both copies succeeded; the local database integrity check passed. Only counts and hashes were inspected/logged. Backup remains private pending the upgrade comparison and must be deleted when that check is finished.
- Device metadata showed pilot build 178 and V2 build 222 before testing. The build 223 install attempt failed with CoreDevice 4016 because the phone became unavailable. No pilot app upgrade was confirmed. Reconnection/unlock requested; Mirroring also requires the phone locked for visual checks after installation.
- Live pilot alias independently confirmed still at `dpl_3PwHFL6urEmpGRoXLoqPfC7d8Uwp`. No live worker activation, pilot TestFlight upload or tester expansion performed.

Next: reconnect device, install the signed candidate, compare private baseline and upgraded storage, inspect existing-data/Light/Dark flows. Then perform controlled live service activation with queue/cron recovery verification and rollback available, followed by internal pilot distribution. Do not treat build readiness or the build-only fictional check as a substitute for those remaining checks.

## Device upgrade and approved live service activation

- After reconnection, pilot build **223** installed and launched over build 178 on the founder iPhone. Pre-launch and post-launch SQLite checks passed integrity and exact row-payload comparisons for records, folders, contacts, preferences, care plans, story edits/messages and saved metadata. All 156 original Documents files were also preserved byte-for-byte.
- Mirroring verified the upgraded home, More Summaries list, saved practitioner summary, care-plan summary, and both top-right Share controls opening PDF preview. Legacy saved prose was kept unchanged; no real-record regeneration or new clinical-quality claim is made by these visual checks.
- Deleted `/tmp/cc-pilot-upgrade-baseline` and all its approved temporary record/document comparison copies after successful preservation verification.
- Automatic approval review initially rejected persisting production summary flags because explicit activation authorization was missing. The user then explicitly answered **“Activate the pilot service”**, authorizing durable record/practitioner/overview summaries with existing accounts/database/credentials and unchanged $10 cap.
- Persisted the reviewed feature configuration. Guarded worker activation checked no queued/running inference and compared the previous worker deployment before switching to `dpl_CCcvo8SqFVLS1af79F8VY87WX55t`. Promoted that release to the existing pilot alias. Previous release `dpl_3PwHFL6urEmpGRoXLoqPfC7d8Uwp` is retained for rollback.
- Vercel project metadata confirms the minute summary-recovery cron is enabled and bound to the new live deployment. Baseline summary policy remains selected; no founder budget or credentials were copied.
- Live fictional queue check `868da113-cbbc-4eb1-a45f-fe5d0bd20827`: submitted without direct worker execution or queue dispatch. The independent recovery schedule and private queue advanced it from queued through 3/3 completed steps (3 calls). Read-only status observation did not advance work. Completion observed at **14:15:29 Eastern**; acknowledgment verified zero parent payloads, child payloads and retained step outputs.
- Build-only activation and queue verification deployments were removed after recording success. No patient input was submitted by these service checks.

The service is now active and the founder phone has the pilot candidate. Wider pilot TestFlight upload/distribution has not occurred. Before distribution, complete returning-account launch-update and fresh-account agreement checks in both Light and Dark appearance (an already-dismissed update is not evidence), plus real-summary acceptance on the upgraded pilot. Existing automated and fictional-data results do not replace these remaining release gates.

## Follow-up acceptance and empty-state audit

- User confirmed the upgraded pilot's real summary generation succeeded.
- Fresh practitioner summary previously exposed Generate with zero records; replaced with first-record guidance and a return action. Toolbar regeneration is disabled with zero records unless unfinished work exists to resume. The same guard applies to care-plan regeneration.
- Empty care-plan guidance now includes visits and notes as sources, alongside uploaded care plans. Existing home first-record guidance and disabled empty care-plan PDF export are retained.
- These follow-up UI changes require a new build; build 223 does not contain them. Light/Dark account acceptance gates remain unverified, and no TestFlight upload has occurred.

- Empty-state follow-up compiled successfully for generic iOS (unsigned Debug); diff whitespace check passed. Record detail source review confirmed missing-detail creation waits for details to load, and empty in-progress summaries show a loading placeholder. These are source/build checks, not completed fresh-account visual checks.
