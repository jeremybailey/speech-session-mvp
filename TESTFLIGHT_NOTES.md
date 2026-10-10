# CollectiveCare TestFlight Notes

## Version 1.0993 (10) — Contact grouping and processing fixes

Signed archive and App Store Connect upload completed October 10, 2026. Apple
accepted build 10 and reported the uploaded package is processing. Browser sign-in
expired; processing completion, export compliance, tester assignment, and What to
Test remain to be confirmed. Jeremy rebuilt and verified the latest contact
presentation on his own records.

Care team & contacts now presents same-name entries under one expandable heading,
retaining independently editable details, differing addresses, and original sources.
Exact duplicate cards group on load; source-backed contact identity review also runs
after record processing. Existing records benefit from the new presentation without
regenerating conditions. Explicit separation and patient choices remain respected.

This client build also includes the historical-status parsing fix, source-check
repair safeguards, condition source-context improvements, a loading placeholder that
only appears during active work, and red condition icons on cream backgrounds.
Category icons under All retain their original colors. Server model settings and
the shared spending cap are unchanged by this release.

Validation: 340 Swift tests, two optional skips, no failures; simulator build passed.
Private export replay preserved every source occurrence in the two reported contact
pairs. This is not a new full clinical-accuracy benchmark.

What to test: open All → Care team & contacts, expand same-name contact groups, and
check that distinct details and original records remain accessible. Confirm condition
loading finishes or offers a retry, and review newly processed details against their
originals. Known clinical accuracy limitations remain.

## Version 1.0993 (9) — Processing reliability

Signed archive, App Store Connect upload, Apple processing, and export-compliance
setup completed October 9, 2026. Build 9 is assigned to the five-tester internal
CollectiveCare Founders group. What to Test is saved. The previously confirmed
standard-encryption/no-France answers were reused; encryption is unchanged.

Source-check batches now run one at a time, preventing simultaneous Luna budget
reservations from unnecessarily stopping a record. Processing failures retain their
specific explanation, including budget limits, rather than showing a generic error
and suggesting repeated retries. The shared spending cap and model policy are unchanged.

Jeremy verified that the local build completed processing his history and reported
improved accuracy. This is user feedback, not a new scored benchmark. The regression
suite completed 292 tests with zero failures and two optional skips; parser checks passed.

What to test: retry unfinished work and confirm processing completes. Review the
result against the original record and report missing or incorrect details. If the
allowance is insufficient, confirm the message names the budget and directs you to
AI usage in Settings. Existing clinical accuracy limitations still apply.


## Version 1.0993 (8) — Summary evaluation beta

Signed archive and upload completed October 9, 2026. Apple processing and export
compliance are complete; build 8 is assigned to the five-tester internal
CollectiveCare Founders group, with What to Test saved. Standard encryption and
no distribution in France were declared, with the latter confirmed by the owner.
The Luna server deployment is Ready on both app aliases; cleanup remains daily.
Release checks: 290 Swift tests (two optional skips), nine scorer tests, parser
and transfer guards, and 14 server tests (two database-dependent skips) passed.

This build preserves more summary context, including who reported a detail,
statement type and status, and medication instructions alongside narrative details.
Newly processed facts must pass the independent source check and exact-citation
requirements before appearing. Internal extraction metadata is removed from display.
The password-protected ZIP export/import workflow from build 7 remains available.

What to test: back up your history, then explicitly reprocess the selected record
from its saved text. Compare displayed details and source links with the human
scorecard. Check medication instructions, attribution, uncertainty, and condition
placement. Importing a ZIP alone does not reprocess it. Report missing details as
well as unsupported interpretations; stricter checks can hide valid information.

This is an evaluation beta. Ambiguous measurements, inferred leakage type, missing
instructions and condition routing remain known concerns in the experimental
benchmark. Review all generated content against its source. The shared evaluation server now uses GPT-6 Luna with medium reasoning for
extraction and checking, Mini for categorization, and the existing condition policy.
The single-record benchmark achieved 2/18 full passes and 13/17 partial retention
against a provisional Draft key; these are not validated accuracy estimates.
The shared spending cap is unchanged.


## Version 1.0993 (7) — Settings data transfer (release in progress)

Signed archive and App Store Connect upload succeeded on October 2. Apple
processing completed; distribution awaits the export-compliance answer for the
new standard AES ZIP encryption. Existing CollectiveCare Founders group includes
Asha and has automatic Xcode-build distribution enabled.

Settings → Data transfer now provides Export data and Import data. There is no
new home-screen section or tab. Export requires a password of at least 12
characters; share the password separately. Leave Include original files off for
a compact transcript/OCR-text and saved-results ZIP. Turn it on for a backup
including saved audio, PDFs, scans, and photos. Restrict sharing of these health
records; encryption does not anonymize them.

Import previews the ZIP file before asking to replace the entire local history.
Export your own history with originals first if you want to restore it later.
Your Kinde sign-in and spending account do not change. Import and reopening do
not start AI processing. Existing explicit record reprocessing, condition
organization, and overview actions remain available under the existing budget.
Text-only exports cannot test audio transcription or OCR accuracy. Old-device
reminders are removed on replacement; imported reminders are not automatically
scheduled on the receiving phone.

The Settings → export → share/save → import flow was successfully checked on
Jeremy's physical iPhone. Offline archive tests cover both original-file modes,
wrong passwords, integrity validation, and replacement/recovery. The October 2
release check passed 280 tests with one skipped and no failures; Settings transfer
guards also passed. Test only consented data; no real exports or answer keys belong in Git.
No paid evaluation or backend changes are part of this feature.

## Version 1.0993 (6) — What to Test

Large histories now upload in resumable chunks instead of one oversized request.
Condition mapping and independent verification remain small, budgeted steps; saved
results and unchanged record summaries are reused. Please retry Organize conditions
on the existing history without deleting or reimporting records. Allow the initial
upload to finish before closing the app. Check completion, source links, and AI usage
in Settings; uncertain associations should remain in All. The spending cap is unchanged.

## Version 1.0993 (5) — What to Test

Condition organization now saves progress on the server and can continue while
the app is closed. Reopening unchanged records reuses saved results. This build
also fixes an overview error caused by internal reference IDs appearing in text.

Please check that conditions finish organizing, remain saved after reopening, and
keep related medications, tests, and follow-ups with the right condition. Tap
Create overview when ready; overview generation is intentionally manual. Review
the results against your records and report missing or incorrect associations.
Settings → AI usage shows estimated API spending. Cloud processing requires the
existing Kinde sign-in; no separate tester enrollment is required. The alpha uses
a shared $1 processing budget; if exhausted, processing stops rather than silently
incurring more charges. Your saved records remain available.

## Beta App Description

CollectiveCare helps testers record medical appointments or scan visit documents, transcribe the content, and generate organized visit summaries. This beta is intended to evaluate capture quality, transcription reliability, and summary usefulness.

## Beta Review Notes

This app is a medical note-taking assistant, not a provider of medical advice, diagnosis, or treatment. Summaries are generated from user-provided recordings or scanned documents and should be reviewed by the user for accuracy before use or sharing.

Audio transcription defaults to on-device WhisperKit; Apple Speech is also available. OpenAI Whisper (cloud) and OpenAI-backed summaries require signing in with the provided authentication flow (Kinde). When those features are used, audio or transcript text is sent from the app to your organization’s API, which forwards requests to OpenAI using a server-side key. **Testers do not paste or store OpenAI API keys in release builds.** Sessions, transcripts, and summaries remain stored locally on the device. Durable cloud jobs temporarily retain clinical processing payloads and results with a seven-day expiry/cleanup policy, while nonclinical usage accounting is retained.

## Suggested Tester Instructions

1. Open **Settings**, sign in under **Account**, and confirm your build includes the organization’s proxy API URL (see internal setup docs).
2. Choose a transcription engine and (if needed) summary engine.
3. Record a short appointment-style conversation or scan a visit document.
4. Open the saved session and compare the transcript and summary against the original content.
5. Check the **Health Summary** tab after creating multiple sessions.

## App Privacy Notes

Data collected or processed by the app may include audio recordings, transcribed text, scanned document text, generated summaries, and authentication identifiers handled by the identity provider when the user signs in. Session data is stored locally on device. Cloud processing occurs only when OpenAI-backed features are used, via your organization’s HTTPS proxy to OpenAI.
