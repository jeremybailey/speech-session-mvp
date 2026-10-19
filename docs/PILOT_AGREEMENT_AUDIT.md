# Pilot agreement acceptance audit

Status: backend deployed on 2026-10-19; client built locally only. No TestFlight upload or distribution. Version `2026-10-19.1` includes the paragraph 3 wording approved on 2026-10-19: no use for AI model training, with temporary retention for processing and interruption recovery. The user confirmed the OpenAI account is configured not to retain data for training. The server version is published for the review client; no real user acceptance was submitted during verification. Any subsequent legal wording change must use a new version and client version check.

## Receipt

`POST /api/v1/agreements/pilot` requires a verified Kinde bearer token. The server derives `owner` from the token subject; it never trusts a client-provided identity or timestamp. Acceptance requires the exact current version, SHA-256 and affirmative action. PostgreSQL timestamps the acceptance and stores the complete text (including the button label), account subject, UUID, app version and build. No health records, email addresses or access tokens are included.

The unique account/version/hash constraint makes concurrent submissions and retries idempotent. A lost response can be recovered by GET without creating another acceptance. Existing acceptance rows cannot be updated or deleted through ordinary DML; privileged database administrators can still alter the schema. This is an audit trail, not a cryptographically tamper-proof or independently witnessed record. It establishes that an authenticated account submitted acceptance, not the real-world identity of whoever held the phone.

The app waits for a matching server receipt before granting entry. A cached server receipt allows subsequent offline use for that account and version. Changing account cannot reuse another account's receipt. The previous device boolean is ignored. Sign-in is now before acceptance, and the testing skip is removed to avoid unattributed consent. A fresh installation requires connectivity to retrieve its existing receipt or accept. Never backfill old booleans as historical acceptances.

## Deployment order

1. Provider training/data-sharing setting: confirmed by the user on 2026-10-19.
2. Migration `009_pilot_agreements.sql` applied in the isolated deployment build with `MIGRATE_PILOT_AGREEMENT=1`. Independent of pending migration 008; no clinical tables changed.
3. Endpoint and registry deployed with production `PILOT_AGREEMENT_VERSION=2026-10-19.1`. The endpoint fails closed if not enabled.
4. Local PostgreSQL route tests passed: authenticated synthetic GET/POST, eight concurrent submissions producing one receipt, lost-response GET recovery, separate accounts, stale hash rejection, forged owner/time ignored, immutable rows and unavailable storage. Production migration performed a synthetic insert/read/repeated-insert transaction and rolled it back. Live endpoint rejected unauthenticated access. No paid model calls or real user acceptances were made. A real signed-in device acceptance remains a manual review step after legal approval.
5. Client Debug build succeeded and four Swift receipt tests passed, including offline encode/decode, account isolation and malformed/stale receipt rejection. TestFlight is intentionally held for lawyer review.

For future published wording changes, create a new version and update the client version check in `PilotAgreementDocument.supportedVersion`. Preserve historical text in receipts and Git; do not edit existing rows. Old clients intentionally cannot accept a new version they do not recognize.

## Administrator audit query

Use the authenticated database console; access should remain limited to authorized administrators. Join `owner` to the Kinde account ID in the authorized account administration interface when a person's identity is needed.

```sql
SELECT id, owner, accepted_at, version, sha256, app_version, app_build, action
FROM pilot_agreement_acceptances
ORDER BY accepted_at DESC;
```

Use `SELECT agreement_text ... WHERE id = ...` to recover exactly what was accepted. Timestamps are `timestamptz`; export in UTC. These legal acceptance records are separate from the short-lived clinical-processing tables and are not purged by processing cleanup. A legal retention schedule for acceptance records remains to be defined; no indefinite-retention promise is made here.

## Deployment record

- Deployment: `https://speech-session-rof40tfb3-jeremy-baileys-projects.vercel.app`
- Production: `https://speech-session-mvp.vercel.app`
- Previous production deployment: `https://speech-session-f3c4cj412-jeremy-baileys-projects.vercel.app`
- Isolated source: base `4bbc2ecc`, plus agreement endpoint, registry, migration and migration build script; pending clinical result-receipt changes excluded.
- Agreement SHA-256: `f616f8b49cf143db7764650041de8a7176fa138b69bff45e8b3e9fa2772d347e`
- Lawyer review copy: `PILOT_AGREEMENT_REVIEW.md`.
