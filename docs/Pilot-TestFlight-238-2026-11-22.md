# Pilot TestFlight — November 22, 2026

- App: CollectiveCare pilot, `com.CollectiveCare.pilot`.
- Version/build: **1.0993 (238)**.
- Archived source: `02e52176b93770b59d3ba195766980f13075e834`.
- Source digest: `2560a6c764a046bf472803b539c01cd3133eabb6eca9e0a21960d51585d259c9`.
- Branch: `codex/pilot-founder-parity`.
- Upload succeeded at **16:19:33 Eastern**. Xcode reported `EXPORT SUCCEEDED`; Apple reported the uploaded package is processing. Tester availability and group distribution are not independently verified.

## Included changes

Founder-equivalent pilot summaries with existing pilot identity and storage; practitioner and care-plan summaries under Summaries; PDF preview before sharing; updated onboarding and consistent bottom actions; direct capture-to-summary transition; automatic detail handoff, corrected partial-completion handling, and subtle pending-detail dots.

## Verification

- Signed Release archive succeeded. Pilot bundle ID, build number, Git commit, backend URL, runtime flags and complete source digest matched the checkout.
- 16 focused tests passed for capture records, incremental record updates and automatic update policy. Three release-gate unit tests passed; whitespace check passed.
- User confirmed the requested returning-user update and fresh-account agreement checks in Light and Dark mode, including enabled/accepting primary controls. This is user-reported visual evidence, not an automated visual test.
- `launchCTALightModePassed`: true (user confirmed).
- `launchCTADarkModePassed`: true (user confirmed).
- Prior upgrade preservation and live service checks are recorded in `PilotCandidate-2026-11-22.md`. User confirmed real summary generation and new-photo detail extraction. No new claim of comprehensive clinical accuracy is made by these release checks.
- Temporary metadata diagnostic deployments were deleted. No service change or spending-cap increase was made for this upload.

## Remaining

Apple processing and tester/group availability. Wider distribution has not been independently confirmed.
