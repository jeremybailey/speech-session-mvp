# Condition workflow: expired cached result

On October 23 a condition workflow stopped at its first mapping step. Read-only production inspection showed that the child job completed on October 12; its clinical payload/result was no longer present. The coordinator reused completed job metadata without checking result availability and classified the missing result as invalid. The latest agreement release did not change condition processing.

## Fix

Workflow child submission checks availability of a completed result before reuse. When unavailable, it uses a replacement identity scoped to the parent and the expired child. Reservations and deduplication remain serialized under the existing budget lock. Running and uncertain jobs are never replaced. Direct job submissions keep their existing behavior.

Explicit resubmission of a previously invalid workflow can resume the unchanged checkpoint when its last child is completed but its result is missing or expired. GET polling cannot resume or charge. Existing structural and independent clinical validation are unchanged.

## Validation

- 81 condition contract/recovery tests passed, with no skips, using an isolated local PostgreSQL database and synthetic inference.
- Regression scenarios cover expired and deleted completed results, concurrent resumption/submission, single claim, successful independent checking, a fresh parent, and preservation of uncertain outcomes.
- TypeScript check passed; broader backend suite: 105 passed, 3 database-dependent tests skipped. The condition database suite was run separately above.
- No patient payload exported and no paid inference executed during diagnosis or tests.

Deployment is limited to ledger.ts and condition-workflow-store.ts from commit 9070a790 plus these tests. Unfinished result-receipt/deletion-policy changes are excluded. User must retry the unfinished condition workflow to validate the complete live run; clinical output was not fabricated or marked successful administratively.
