# V1 audit citation recovery — November 28, 2026

The source-coverage guard added November 24 rejected an audit that shortened an existing point while dropping one of its two citations. Today's app presentation/profile changes did not deploy that backend.

The fix shares the same required-source list between the prompt and validator. Founder audit/publication requests explicitly preserve all supporting source IDs when combining points. An audit that passes all other validation but lacks source coverage can use the existing audit-reference retry limit (attempt < 2). No new states, schema, model, budget, queue, or repair service. Rejected output is never patched with guessed citations.

State path: running → retry_scheduled → running → completed, or needs_attention if validation still fails at attempt 2. Existing saved failures require revision-checked explicit resume. Completed checkpoints and child receipts remain intact. Cancellation, expiry, ownership and total-call limits retain their existing behavior.

Validation: TypeScript passes; backend suite 294 passed, 8 unrelated database-dependent tests skipped, zero failures, including the real local PostgreSQL summary-workflow test. Synthetic coverage checks exercise retry exhaustion, concurrent explicit resume, successful completion, retained checkpoints, invalid content rejection and legacy behavior. Read-only replay of the saved production receipt confirms source-only eligibility; no clinical text is stored here.

Production deployment and saved-run recovery: pending verification.
