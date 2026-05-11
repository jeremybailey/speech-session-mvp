# CollectiveCare TestFlight Notes

## Beta App Description

CollectiveCare helps testers record medical appointments or scan visit documents, transcribe the content, and generate organized visit summaries. This beta is intended to evaluate capture quality, transcription reliability, and summary usefulness.

## Beta Review Notes

This app is a medical note-taking assistant, not a provider of medical advice, diagnosis, or treatment. Summaries are generated from user-provided recordings or scanned documents and should be reviewed by the user for accuracy before use or sharing.

Audio transcription can run on device with Apple Speech or WhisperKit. OpenAI Whisper (cloud) and OpenAI-backed summaries require signing in with the provided authentication flow (Kinde). When those features are used, audio or transcript text is sent from the app to your organization’s API, which forwards requests to OpenAI using a server-side key. **Testers do not paste or store OpenAI API keys in release builds.** Sessions, transcripts, and summaries remain stored locally on the device except for what is sent for each cloud request.

## Suggested Tester Instructions

1. Open **Settings**, sign in under **Account**, and confirm your build includes the organization’s proxy API URL (see internal setup docs).
2. Choose a transcription engine and (if needed) summary engine.
3. Record a short appointment-style conversation or scan a visit document.
4. Open the saved session and compare the transcript and summary against the original content.
5. Check the **Health Summary** tab after creating multiple sessions.

## App Privacy Notes

Data collected or processed by the app may include audio recordings, transcribed text, scanned document text, generated summaries, and authentication identifiers handled by the identity provider when the user signs in. Session data is stored locally on device. Cloud processing occurs only when OpenAI-backed features are used, via your organization’s HTTPS proxy to OpenAI.
