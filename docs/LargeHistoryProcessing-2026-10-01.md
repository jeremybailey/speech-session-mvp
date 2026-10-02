# Large-history processing repair

## Cause

The app serialized all facts through a 400 KB single-inference helper even before
filtering preserved context. The completed workflow manifest had a second 400 KB
limit; the backend also limited manifests to 100 batches. Verification repeatedly
included all accepted members of a growing condition, creating another size and
cost bottleneck after upload.

## Changes

- Keep inference batches at 30 entries / 24 KB. Never truncate a large single entry.
- Construct the full manifest separately from single-inference input validation.
  Upload only grouped preserved context, not unrelated preserved unassigned text.
- Upload manifests over 350 KB in 240 KB raw-byte chunks, base64 encoded for JSON.
  Stable SHA-256 digest plus authenticated owner identifies an upload. Status lists
  acknowledged chunks; relaunch resends only missing chunks. Repeated/conflicting
  chunks, missing pieces and digest mismatches cannot initiate inference.
- Finalize upload and create/reuse the workflow in one database transaction.
  Cancellation has a persistent tombstone, including before finalization. Upload
  itself reserves/spends no model budget; existing ledger reservations govern all
  subsequent calls. Shared budget and uncertainty/no-automatic-retry rules unchanged.
- Download large completed results in bounded chunks with end-to-end digest checking.
- Preserve existing request identities for small catalogues and context. For larger
  ones, retrieve at most 15 KB of catalogue and 8 KB of complete, deduplicated context
  per proposed group. Lexical retrieval is not an association decision. Explicit
  incomplete-context notices instruct the independent verifier to reject uncertain
  links. Original source remains intact and no saved association is removed by retrieval.
- Keep seven-day clinical upload expiry/cleanup and owner isolation. Migration 007
  adds tables only; existing accepted mappings and extraction caches are untouched.
- Distinguish an oversized individual detail from whole-history failures; remove
  blanket advice to retry an unchanged request after a size rejection.

## Bounds and limitations

This is bounded processing, not unlimited input: complete manifests have a 60 MB
safety ceiling, at most 256 upload chunks and 10,000 inference batches. Individual
details over the safe batch size stop explicitly rather than being truncated. Large
catalogue/context retrieval may leave uncertain associations unassigned; it cannot
guarantee complete recall. No paid quality or Asha-data rerun was performed here.

## Offline verification

- 900 synthetic facts exceed the old manifest cap, preserve every occurrence and
  produce stable manifests with bounded individual batches.
- PostgreSQL: >400 KB / 430-batch upload; interrupted/missing chunks; repeated and
  concurrent finalization; owner isolation; cancellation before/after finalization;
  expired payload cleanup; zero inference jobs during upload/finalization.
- 1,200 preserved records in one condition and 1,500-condition catalogues keep
  requests bounded without deleting accepted links.
- 15,000-ID result downloads reassemble exactly and verify their digest.
- Existing independent verification, manual choices, completed-step reuse, uncertain
  charges and budget exhaustion regressions remain in the test suite.
- Swift: 265 tests, one skipped, zero failures. iOS build and transport compile passed.

Deployment requires migration 007 before the new backend, followed by a new app build.
Do not promote the migration-only Preview: it intentionally uses mocked inference.

## Rollout

Migration-only Preview `dpl_71bh5D6fNEo9jQVYDPwRPDGsa47N` applied migration 007
successfully without inference. A separate clean Production deployment,
`dpl_6ULCe82roh7Qy2wYGZtJNerztLzp`, is live. Its deployment gate verified the new
tables and intact existing budget; anonymous upload/usage requests return 401.
The app distinguishes resumable upload progress from server-side processing.
Build 1.0993 (6) was signed and successfully uploaded to App Store Connect for
TestFlight. Apple reported the package is processing; tester availability and
real-data completion remain unverified. No tester notification/group change was made.

Disposable simulator/repository/Xcode derived-data caches were removed to recover
disk space (about 13 GB free afterward). Source, archives, simulator data and the
current working build cache were preserved. The local synthetic PostgreSQL server
was stopped after tests. No paid model requests were made by these checks.
The final disk check showed about 32 GB available after cache cleanup/purging settled.
