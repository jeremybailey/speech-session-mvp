# Whole-history comparison

This harness is intentionally private and source-only. Patient inputs, outputs,
judgments, snapshots, credentials and reports belong under ignored
`build/benchmarks/`; never commit them or attach them to a public issue.

Preparation preserves both original dirty checkouts and integrates their changes
in an isolated copy. `prepare_dataset.py` verifies authoritative original export
hashes, keeps record boundaries, IDs, dates and source references, and freezes the
unchanged answer key separately. An unresolvable hash mismatch is a hard stop.
No generated summary, preference, profile or answer-key label enters inference.

`compile.py` builds the current complete `HealthSummaryModel.updateHealthStory`
flow. Only device-only APIs and networking are adapted for a Mac replay. It links
the combined copy's persistence library; do not use the root library or old
build-10 harness. Defaults and stores are private. Baseline clinical prompts,
chunking, validation, repair policy and care-plan logic remain current.

`prepare_backend.py` installs candidate policy only in a private, expiring,
authenticated diagnostic copy. Its server admission gate checks the entire
experiment prefix under the shared budget row lock, after idempotency lookup.
Settled costs plus unknown/outstanding reservations cannot exceed $5. The shared
pilot cap and historical speed-experiment accounting are untouched. Deployment
uses `--skip-domain`, no queue triggers or cron and no maintenance/migration
build scripts. Verify pilot aliases before and after deployment and cleanup.

Run synthetic contract and local PostgreSQL ledger tests before paid work. Record
gates, build and test results, server runtime policy and a frozen clinical rubric,
then use `freeze.py`. `run.py` verifies hashes before dispatch. Each repetition has
fresh run owners and stores. C receives that repetition's B output. No paid retry,
automatic split or replacement is made for B/C. A retains the app's current
explicitly pinned repair policy. A failed run is not a speed win.

B/C use Luna medium and 64,000 maximum output tokens including reasoning. Context
preflight uses a conservative UTF-8-byte upper bound plus envelope allowance;
no extra token-counting provider call is required. Local integrity validation
checks every quotation and record/entity reference. This is not semantic clinical
verification. B is never imported into an app or labeled checked patient data.

Use the existing explicit item scorer plus `score_graph` in
`../score_scorecard.py` for Conditions and Relationships. Bind judgments to exact
key and output hashes. Review additions, omissions and care-plan ownership
individually against source-backed occurrences. The frozen key is Draft-only:
all findings remain provisional even if three runs complete.

Report harness elapsed time (including CLI/network bridge overhead), provider
and queue timing where available, actual request/token/cost accounting and all
outstanding reservations. Attribute B's full generation time/cost to both B and
C, but count it once against actual spend. Advance only with complete runs,
no unresolved material regression, lower median cost and at least 50% lower
median elapsed time. Never infer success from partial output.

Finally purge only the scoped clinical payloads, cancel undispatched jobs, retain
ledger rows and unresolved charges, remove every diagnostic deployment and local
temporary credential, and verify pilot aliases again. Keep reproducible hashes,
source-local private artifacts and accounting evidence. No production release is
part of this experiment.
