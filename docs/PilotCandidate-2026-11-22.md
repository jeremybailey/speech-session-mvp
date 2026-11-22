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
