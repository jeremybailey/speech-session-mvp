# CollectiveCare TestFlight Notes

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
