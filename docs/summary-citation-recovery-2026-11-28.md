# V1 audit citation recovery — November 28, 2026

The source-coverage guard added November 24 rejected an audit that shortened an existing point while dropping one of its two citations. Today's app presentation/profile changes did not deploy that backend.

The fix shares the same required-source list between the prompt and validator. Founder audit/publication requests explicitly preserve all supporting source IDs when combining points. An audit that passes all other validation but lacks source coverage can use the existing audit-reference retry limit (attempt < 2). No new states, schema, model, budget, queue, or repair service. Rejected output is never patched with guessed citations.

State path: running → retry_scheduled → running → completed, or needs_attention if validation still fails at attempt 2. Existing saved failures require revision-checked explicit resume. Completed checkpoints and child receipts remain intact. Cancellation, expiry, ownership and total-call limits retain their existing behavior.

Validation: TypeScript passes; backend suite 294 passed, 8 unrelated database-dependent tests skipped, zero failures, including the real local PostgreSQL summary-workflow test. Synthetic coverage checks exercise retry exhaustion, concurrent explicit resume, successful completion, retained checkpoints, invalid content rejection and legacy behavior. Read-only replay of the saved production receipt confirms source-only eligibility; no clinical text is stored here.

Production verified Ready and active: `dpl_2prnWosZd43fgpRFipCgGAxc7sTw`, V1 alias `collectivecare-fork-b-recovery-test.vercel.app`. Anonymous API access returns 401; private queue/source paths return 404. Activation compared the previous deployment ID before updating the existing worker fence.

The saved failure resumed with its expected revision, retained all six completed checkpoints, passed the repaired audit at attempt 2, and completed all nine steps with no error (11 calls of the existing 18-call maximum). Three additional calls covered audit, consolidation and final publication checking. The result is saved server-side; device receipt was still unacknowledged at verification. The existing $10 budget ceiling, model policy, app build and V2 were unchanged. No clinical text or credentials are included in this record.
