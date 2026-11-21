# Canadian privacy review checklist (Kinde + OpenAI proxy)

Use this with counsel for PIPEDA / provincial health privacy expectations. It does not constitute legal advice.

## Authentication (Kinde)

Collect and retain for your records:

- Executed **Data Processing Agreement** (DPA) with Kinde, if applicable.
- Current **subprocessor list** and notification process for changes.
- **Data residency / region** options for auth metadata, if required for your program.
- Available **SOC 2 / ISO** (or equivalent) attestations relevant to their service.

**Data in scope for Kinde** is typically authentication and profile fields you configure (for example email, name)—not visit transcripts if those are not sent to Kinde.

## Application content (OpenAI via your proxy)

Separately assess the path **device → your proxy → OpenAI**:

- **Transparency**: What is described to users (TestFlight notes, in-app copy, privacy policy) about audio/transcripts leaving the device.
- **Subprocessors**: OpenAI and your hosting provider (for example Vercel) should appear in disclosures where personal health information may be included.
- **Logs & storage**: Confirm inference routes do not persist request bodies or unnecessary identifiers; rate limiting may use stable subject IDs from JWT `sub` if implemented.
- **Cross-border transfer**: Document whether processing occurs outside Canada and what contractual or consent bases apply.
- **Retention**: Cloud summarization may temporarily retain prepared text, checkpoints and results solely to finish processing and recover interruptions, as described in pilot agreement 2026-10-19.1. Purge live job content after the phone confirms a durable result save; unacknowledged work has a seven-day expiry and cleanup policy. Retries must not extend that deadline. Verify backup, hosting-log and provider retention separately; application expiry is not a physical-erasure guarantee for those systems. Original files stay on the phone for this summary-coordination workflow.

## App Store

Align **App Privacy** answers with: local storage of clinical notes, optional network use for summarization/transcription, sign-in for cloud features, and removal of “user-supplied third-party API key” for production.
