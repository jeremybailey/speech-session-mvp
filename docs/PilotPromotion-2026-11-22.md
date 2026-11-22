# Pilot promotion assessment — November 22, 2026

Assessment only; no pilot branch, database, deployment or distribution changed.

## Compared releases

- V2 candidate: `064ab54daa89db5c3edc20db636ca7398b58dc05`, build 222, `com.CollectiveCare.storylab`.
- Pilot branch: `origin/codex/pilot-production`, `269f65f`, configured build 178, `com.CollectiveCare.pilot`. These are repository settings, not a live App Store inventory.
- Pilot backend in source: `https://collectivecare-fork-b-recovery-test.vercel.app/api`; V2 uses `https://collectivecare-story-lab.vercel.app/api`.
- A non-mutating merge preview found conflicts in `SpeechSessionApp.xcodeproj/project.pbxproj` and `SpeechSessionApp/SessionDetailView.swift`. Pilot has three unique commits retaining pilot identity and launch-update presentation.

## Required promotion work

1. Prepare a candidate from the pilot branch and merge the V2 changes. Resolve the two conflicts; review automatic merges, especially launch/onboarding and data loading. Keep pilot bundle IDs, app groups, URL schemes, authentication configuration, backend URL and launch update. Update manifest inputs and bind the candidate's actual Git commit when archiving.
2. Stage the matching service on the pilot deployment. Apply additive migration `013_summary_workflows.sql`; verify all execution/dispatch policy fences. Verify private queue delivery, minute recovery cron, worker deployment ownership, result retrieval and cleanup before enabling submissions. Inspect current pilot settings instead of copying founder credentials, budgets or feature flags.
3. Explicitly review the accelerated summary policy: current readiness checks restrict `AI_SUMMARY_PARALLEL_V2` to the founder configuration. Promote a tested policy deliberately or retain the baseline policy; do not bypass this check just to match founder speed. Check pilot concurrency and budget capacity for simultaneous chat and summaries.
4. Test an in-place upgrade with representative existing pilot data: records, source files, edits, removed details, category overrides, contacts, saved summaries and in-flight work. Confirm sign-in, share extension, recording/Live Activity and existing import/export paths still work. Never replace pilot storage with founder data.
5. Run summary correctness and recovery checks: history and event dates retained, named clinicians supported by sources, medication/decision qualifiers preserved, no invented details; lock/force-quit/return and Retry resume saved work; chat answers during summary generation; both PDF previews and sharing work. Verify temporary service data is purged after acknowledgment and cancellation/expiry.
6. Run the pilot-required launch update and fresh-account agreement checks in both Light and Dark appearance; record `launchCTALightModePassed` and `launchCTADarkModePassed`. Verify source identity in the release archive. Upload to the pilot App Store record, initially distribute to the founder/internal group, then expand after acceptance.

## Rollback

Retain the prior pilot release and deployment configuration. Disable new summary submissions if necessary while continuing accepted work, result retrieval and deletion. Do not assume downgrading the app restores an older local schema; verify upgrade compatibility before distribution.

The code merge is bounded; backend readiness and an actual existing-data upgrade test are the material gates. No elapsed-time estimate or claim of live pilot readiness is established by this source review.
