# Condition mapping evaluation — 2026-09-30

## Result

GPT-6 Luna, **medium reasoning**, passed all **8 synthetic cases / 32 records**
using compiled production Swift prompts and schemas, the production workflow
coordinator, independent verifier, queue worker, and server cost ledger.
One record was already accepted context; 31 were mapping candidates.
No required links were missing, unsupported associations accepted, or invented
diagnoses found in this final evaluation set. Saved outputs were also inspected.
This small synthetic set does not establish accuracy on Asha's full history.

Final run: **$0.003366400 estimated API cost**, 16 paid requests, zero retries,
zero unresolved charges. All Mini and Luna evaluation iterations combined:
**$0.012503900** of the original **$1** allowance; nothing reserved or unresolved.
Provider billing is authoritative. Infrastructure cost is excluded.
No attributable historical baseline was available: **no verified 10× claim**.

Two identical resubmissions of completed pregnancy job
`d304466e-1027-4004-808a-0a13202b64be` returned that same completed job, with
**zero new inference requests and $0 additional cost**. Ledger count and shared
budget usage were unchanged; reserved balance remained zero.

The adjacent JSON receipt contains only nonclinical identifiers, model/settings,
fixture names, outcomes, and costs—not source text, patient names, or credentials.

## Failures retained, not hidden

- Mini iterations cost $0.004722300. They exposed missing care context,
  unsupported chronicity, and an accepted unrelated hormone/migraine association.
- Luna low, first run: 6/7 passed, $0.002587100; the verifier omitted eye history.
- With clarified historical/negative-finding verification, Luna low passed 4 of
  5 attempted regressions, $0.001828100; it incorrectly rejected an explicit
  same-problem dry-eye association. Remaining three cases were not run.
- Luna medium, same revised prompts and unchanged expectations: 8/8 passed,
  $0.003366400. Added a chronology-only/unrelated-negative-finding control;
  it remained unassigned. No failing assertion was relaxed.

## Reproducibility and safeguards

- Deployment: `dpl_41QyPjQDHoBE6bFHEN6ue4RN2z2p` (protected diagnostic Preview).
- Contract digest: `07be802e98fbc76b1e62302fed495ef4ee2dc1a38586d903c2c0712a90faedaf`.
- Model `gpt-6-luna`; reasoning `medium`; maximum output 6000; Standard tier;
  explicit prompt caching with no breakpoints, so no cache-write charges.
- Model and reasoning are pinned per workflow and child job. Configuration
  changes do not invalidate already accepted results.
- Worst-case full-context reservations, versioned pricing, and no automatic
  retry of uncertain charges remain enforced. Budget is shared across iterations.
- Migrations 003–006 applied additively to the evaluation database. Historical
  parent attribution is unknown where it was not tracked; it is not fabricated.
- Eleven backend tests passed with real disposable PostgreSQL databases. Full
  Swift suite passed (263 tests, one skipped); final focused synthesis suite,
  workload-label test, Settings report privacy/arithmetic tests, and iOS simulator
  build passed. Local test database was stopped afterwards.

## Rollout boundary

Production and the physical app were not changed. Never promote this diagnostic
Preview: its temporary endpoint is fixed-synthetic-only and is not part of the
application source. The candidate pilot setting is Luna with medium reasoning,
not the default Mini or Luna low.

Authenticated end-to-end app integration, full import/extraction background
sequencing, the controlled escalation policy, and real workload cost measurement
remain rollout work. The tested durable server sequence covers condition mapping
and independent verification, not the entire import pipeline.
