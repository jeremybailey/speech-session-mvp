# Collective Care V2 — TestFlight upload, November 21, 2026

The user authorized GitHub publication and TestFlight upload after confirming a fresh practitioner summary succeeded.

- App: Collective Care V2 (`com.CollectiveCare.storylab`), separate from the earlier pilot.
- Version/build: **1.0993 (219)**.
- Archived source commit: `77c1011906535b49a9fd7931404e2084948dbb48`.
- GitHub branch: `codex/editable-health-story`.
- Backend: `https://collectivecare-story-lab.vercel.app/api`.
- Active service release at upload: `dpl_5pu3pmfWyPry747j4SRoCW4hgoFJ`.
- Xcode reported **Upload succeeded / EXPORT SUCCEEDED** at 13:54 Eastern. Apple reported the package is processing. Tester availability and group distribution have not been independently verified.

## Included changes

- Durable practitioner summary processing and recovery of unfinished work.
- Short activity labels beside completed/total summary steps.
- Source-checked history coverage and targeted audit reference repairs.
- Fuller care-plan content and grouped presentation from saved practitioner summaries.
- Chat retry and recovery, independent of overview refresh, with actionable capacity errors.
- Record summary templates, contextual details, and practitioner PDF presentation improvements developed on this branch.

## Release verification

The Release archive succeeded. Its bundle ID, build number, embedded Git commit, and source digest were verified against the checkout before upload. The latest backend suite passed 284 tests; nine database integration tests were skipped. Recent chat persistence checks passed 19 tests. The user confirmed a fresh summary completed successfully before this upload.

Release packaging required refreshing the manifest input list and explicitly binding its Git commit so build isolation could not resolve a parent repository. The initial build 218 upload attempt was interrupted before a success receipt; build 219 is the verified successful upload.

The founder processing allowance is $25, explicitly approved November 21. The release readiness check recognizes that allowance only for the founder project and budget. Other installations retain their prior ceilings.
