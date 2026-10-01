# Single-account production pilot — 2026-09-30

## Deployed and verified

Production deployment `dpl_Rjni4PS6Xaob1U4z8SULFqWWkATy` is live at the existing
`https://speech-session-mvp.vercel.app` domain. Built from clean application source,
not the diagnostic Preview. `/api/condition-evaluation` returns 404; the condition
workflow endpoint returns 401 without authentication.

Existing database, deduplication, cleanup and budget settings were extended to
Production without exposing or changing their secret values. The same ledger and
$1 evaluation/pilot ceiling are used. New durable processing is restricted to the
hashed subject of the account authenticated on the connected iPhone. An absent,
malformed or wildcard production allowlist enables nobody. Other accounts are not
enrolled and retain their legacy behavior. The enrolled account cannot use the
unbudgeted legacy inference or cloud-transcription endpoints.

Luna medium, queued continuation, real inference through the ledger, and both app
durable flags are enabled. Production build checks verified all required database
columns, the intact shared budget, one-account scope and model settings. No model
requests were made by deployment or connection checks.

The signed Debug app was installed over the existing iPhone app without deleting
its records. Its read-only diagnostic confirmed:

- authenticated production HTTP 200;
- both durable routes enabled;
- this account is admitted by the production guard;
- server usage is available;
- nine saved source records and 68 facts remain; condition organization is pending.

Routing/error tests, nonclinical usage-report tests, backend type checking and
pilot isolation tests passed. The device build succeeded. Existing extension
build-number mismatch warnings remain (extensions 17, parent 4); no version bump
or distribution to Asha was performed.

## Approved live run and reopening verification

After explicit user approval, normal launch processed the 68 saved facts.
Authenticated phone diagnostics confirmed `latestJobStatus=completed`,
`needsConditionOrganization=false`, and all nine source records / 68 facts retained.
The job's estimated API cost was $0.005695500. A normal relaunch followed by another
read-only check confirmed the saved result and unchanged job cost. No reimport was
performed. The app was then returned to normal launch mode.

The shared ledger reports $0.018199400 used and $0 reserved against the $1 ceiling,
leaving $0.981800600. This equals prior evaluation spend ($0.012503900) plus this run.
These checks establish processing completion and persistence, not a clinical audit
of every association or a verified 10× improvement. Asha remains unenrolled.

The user's earlier manual test used the old Astra path and is not included in this
ledger total. Provider billing remains authoritative.

## Manual overview rejection diagnosis

Authenticated read-only retrieval of the retained overview confirmed valid fact
references, but failed numeric grounding. Five full internal fact identifiers had
leaked into the sentence text. Removing those identifiers made numeric grounding
pass against the unchanged 68 facts. No inference was invoked by this diagnosis.

The app now removes exact known sentence-cited identifiers from presentation prose
before validation, preserving the structured factIDs and all clinical numbers.
Unknown identifiers and unsupported clinical numbers remain rejected. The error
no longer claims that a rewrite and second check occurred when neither did.
All 11 StoryOverviewTests pass, including this regression and invented-number
rejection. The request prompt/cache identity is unchanged so existing results can
be reused rather than regenerated.

The signed fix was installed on the phone. A GET-only check against the retained
production response confirmed both cleaned reference validation and numeric
grounding pass; nine records and 68 facts remain. The app was returned to normal
mode. The user then confirmed that Create overview worked.

## TestFlight alpha preparation

The owner explicitly approved removing the separate account allowlist for all
current and future Kinde-authenticated users. Production deployment
`dpl_5AWnfouVnZGeAFNVaZwjthwW2Kpk` is live with that change; Kinde authentication,
owner isolation and the shared $1 budget remain. Anonymous jobs and usage requests
both return 401. No inference was needed for deployment checks.

Release archive 1.0993 (5) includes the verified overview fix and durable flags.
Both embedded extensions now match the app version/build. Offline validation:
264 Swift tests, one skipped, zero failures; 10 backend tests passed, two database
tests skipped in this run; routing and usage-report checks passed.

Xcode successfully exported and uploaded build 1.0993 (5) to App Store Connect;
Apple reported the uploaded package is processing. The browser session expired
when checking TestFlight, so final processing status and tester distribution are
not yet confirmed. No tester group assignment or notification was performed.
App Store Connect is left open for the owner to sign in and complete that check.
