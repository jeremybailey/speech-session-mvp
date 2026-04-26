# CollectiveCare TestFlight Notes

## Beta App Description

CollectiveCare helps testers record medical appointments or scan visit documents, transcribe the content, and generate organized visit summaries. This beta is intended to evaluate capture quality, transcription reliability, and summary usefulness.

## Beta Review Notes

This app is a medical note-taking assistant, not a provider of medical advice, diagnosis, or treatment. Summaries are generated from user-provided recordings or scanned documents and should be reviewed by the user for accuracy before use or sharing.

Audio transcription can run on device with Apple Speech or WhisperKit. If testers select OpenAI Whisper, recorded audio is uploaded to OpenAI for transcription. If testers select OpenAI summaries, transcripts and saved session summaries are sent to OpenAI to generate the medical summaries. The OpenAI API key is entered by the tester and stored only on the device.

## Suggested Tester Instructions

1. Open Settings and choose a transcription engine.
2. If using an OpenAI-backed feature, enter an OpenAI API key.
3. Record a short appointment-style conversation or scan a visit document.
4. Open the saved session and compare the transcript and summary against the original content.
5. Check the Health Summary tab after creating multiple sessions.

## App Privacy Notes

Data collected or processed by the app may include audio recordings, transcribed text, scanned document text, generated summaries, and user-entered OpenAI API keys. Session data is stored locally on device. Cloud processing occurs only when an OpenAI-backed feature is selected.
