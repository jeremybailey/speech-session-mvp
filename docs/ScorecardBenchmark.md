# Scorecard benchmark workflow

The first run uses the consented export's saved transcript and saved processing results.
It does not measure transcription/OCR accuracy or call an inference service.
The scorecard remains read-only. Real source text, keys, outputs, and judgments belong
under the ignored `build/benchmarks/` directory, never in committed fixtures.

## Capture and replay

1. Read workbook metadata, then bounded ranges from Records, Conditions, Expected items,
   Relationships and Start here. Save a dated JSON snapshot with `sheets[tab].values`.
   Store explicit `selectedRecordIDs`; never interpret sheet row order as completion.
2. Run the opt-in snapshot test on the unzipped export. It validates source and metadata
   hashes, copies metadata into a temporary store, and uses production SessionStore,
   HealthMemoryProjection, condition projection and health-area routing. Patient edits
   and saved preferences remain part of the observed baseline. No app store is modified.

```sh
SCORECARD_ARCHIVE='/path/to/unzipped-export' \
SCORECARD_OUTPUT="$PWD/build/benchmarks/run/baseline.json" \
SCORECARD_RECORD_ID='selected-record-uuid' \
swift test --filter ScorecardSnapshotTests
```

The output directory must already exist. Without these environment variables the test
skips. The replay includes the full archive's condition context, then reports only the
selected record. It is an exported-state baseline, not a fresh isolated model run.

## Review and score

Semantic judgments are explicit, source/output-reviewed sidecars. Do not match solely
by keywords, label every unlisted output a hallucination, or count source excerpts and
hidden cards as visible clinical content. Multiple output entries may jointly satisfy
one expectation. Keep unrelated, historical and current occurrences distinct.

Each judgment records matched output IDs, extracted/visible core presence, required
dimension Pass/Fail/Not scored results, and a qualitative explanation. Match IDs must
belong to the selected record. Bind the sidecar to SHA256 of both frozen key and output.
The current adapter scores Expected items only; a comprehensive runner must also score
Conditions and Relationships as separate rows. Condition routing is currently assessed
within each expected item's dimensions. Matching/adjudication is not automated.

```sh
python3 scripts/score_scorecard.py \
  --key build/benchmarks/run/scorecard.json \
  --output build/benchmarks/run/baseline.json \
  --judgments build/benchmarks/run/baseline-judgments.json \
  --report build/benchmarks/run/baseline-score.json --include-draft
```

The JSON report includes a CSV with row results and reasons. Drafts only enter the
explicit provisional score. Reviewed-only denominators remain separate; zero eligible
rows yield no percentage. Unresolved and Ambiguous expectations remain excluded.
Ambiguous mapping excludes mapping dimensions, not an otherwise scorable fact.
All applicable dimensions and visibility must pass for a positive row to pass. A
forbidden claim passes only when absent from visible output. Core presence is a
partial-retention diagnostic, not a full correctness score. Missing visibility can
cause downstream dimension failures; do not sum those as independent lost facts.

The first assessment is agent-reviewed and still needs human adjudication. Asha's
draft key contains open clinical judgments and a duplicate condition above its header;
these are recorded in the private report, not silently repaired or treated as approved.

## Candidate verification and next cloud replay

`python3 scripts/test_summary_parser.py --export-contracts /path/to/contracts.json`
compiles the app's actual parser and prompt assembly against the built persistence
library, tests synthetic objects, and optionally exports extraction contracts. Run
`swift test` first; this script expects Xcode SwiftPM products in `.build/out`.

Replaying saved output can prove deterministic parsing/display behavior only. For a
fresh quality comparison, use the approved authenticated, budgeted production processing
route and the same source. Capture extraction, classification, verification/admission,
condition mapping, and final visibility separately. Use the original prompt baseline
and candidate with the same model/settings/context, retain costs/runtime from the real
ledger, and rescore both against the same key. Never feed expected answers into generation.
Do not use an unbudgeted API-key shortcut, relax the key after seeing failures, or
promote the candidate merely because local tests pass. No clinical candidate has been
promoted to the live app.

### First fresh replay (2026-10-09)

The private artifacts under `build/benchmarks/2026-10-09/cloud/` contain the first
isolated-record baseline/candidate comparison, source-code hashes, stage receipts,
row judgments and combined CSV. Both compile the actual RecordSummaryProcessor;
only the transport is adapted to a protected diagnostic endpoint. Baseline and
candidate share the current persistence/display projection and differ in the
VisitSummaryModels parser/prompt implementation. Exclude archived preferences,
topics, profile and prior-pair decisions before calculating fresh condition input.
The earlier saved-export projection is a different experiment, not the control
for the fresh candidate.

Full expected-item passes remained 1/18 in both variants. Partial visible retention
rose from 6/17 to 8/17, while visible invented-year dates fell from 9 to 0 and
internal labels in visible prose fell from 4 to 0. These are single-run,
agent-reviewed observations against Draft labels, not general accuracy claims.
No positive row passed every required dimension. Unsupported visible assertions
remain, so the candidate is not release-ready.

The checker frequently cited draft labels instead of source passages. Removing
empty optional display placeholders in one four-item probe did not establish a
successful fix. Every visible entry in the two runs had sourceLinked admission,
not supported admission: display eligibility is not independent verification.
Prioritize checker quality and admission behavior before further prompt tuning.

The existing shared $1 ledger cap was unchanged. The 74 requests had $0.05902815
in settled cost and one uncertain optional recovery request holding $0.0228;
that request was not retried. Production credentials remained server-side.
Temporary diagnostic deployments were removed after receipts were captured.
Vercel unexpectedly moved a secondary alias despite --skip-domain; it was
restored before inference. Both live aliases and scheduled cleanup were verified
afterward. Do not assume --skip-domain alone preserves every generated alias.
Temporary local access files were deleted; the spreadsheet was not edited.

### Second pass: checker-only replay (2026-10-09)

The private `build/benchmarks/2026-10-09/pass2/` report rechecks the same 44
candidate drafts and 15 source windows, then reruns production condition grouping.
Extraction and the frozen Draft key are unchanged. `SummarySourceCheck` projects
populated clinical values without empty display placeholders or prior verdicts.
New checks cannot use the title-word source-link fallback, and explicit exclusions
override inconsistent approvals. Version 20 / clinical-pipeline-v2 prevents mixing
old admission checkpoints into a resumed run. Legacy visibility and patient edits
remain intact until reprocessing.

The experiment also overrides the checker to the existing server-supported
gpt-6-luna/medium policy. Production checking policy is unchanged; the local Swift
patch alone does not reproduce this result with the current Mini default. Two
matched Mini probes were retained, not a full model ablation. Request design,
admission and model changed together, so their individual effects are not isolated.

Full expected-item passes remained 1/18, all from the forbidden-diagnosis absence
row. Partial visible retention rose from 8/17 to 9/17; extracted retention stayed
13/17. Visible entries fell from 23 to 15. Eighteen model approvals became 15
accepted entries after exact-source citation validation. Passing this gate is not
proof of clinical correctness: a speaker-attribution error survived. Four expected
core meanings became visible and three were lost. The detailed private report
records both gains and losses; fewer visible cards alone is not an improvement.

All 19 requests completed at $0.0213849 settled cost, under the unchanged shared
$1 cap. There were no new uncertain reservations. The full Swift suite ran 287
tests with zero failures and two optional skips; nine scorer tests and production
parser checks passed, and the app processor compiled for the replay. The temporary
deployment and local access files were removed; both live aliases and scheduled
cleanup were verified. No candidate was released and no spreadsheet cells changed.

Next, improve draft representation and repair supported claims before rechecking:
preserve attribution, uncertainty and timing, distinguish offered care from received
treatment, and retain exact source spans. Checker-only work cannot recover facts
missing from extraction. Require progress on full row passes and a second labelled
record before considering a pilot release.

### Third pass: draft fidelity (2026-10-09)

The private `build/benchmarks/2026-10-09/pass3/` report compares a fresh isolated
replay with the second-pass output. `ClinicalDraftFormat` requires a clinical
title, details and source excerpt, with typed optional attributes. The parser
retains visible attribution/type/status fields, preserves medication directions
alongside narrative details, and chooses canonical properties deterministically.
Malformed structured objects cannot become metadata-only clinical cards. Legacy
valid objects and text lists remain readable. Version 21 / clinical-pipeline-v3
separates these drafts from earlier checkpoints.

Two bounded Mini probes exposed format and interpretation failures. The full run
uses the existing reasoning model for extraction as well as checking, while
classification stays Mini and condition policy stays unchanged. Its first paid
reasoning extraction was reused. Model, prompt and representation changes are
combined; this is not a prompt-only ablation. Live model policy remains unchanged.

Provisional full passes rose from 1/18 to 2/18, partial visible retention from 9/17
to 13/17, and extracted retention from 13/17 to 16/17. Of 70 drafts, 61 received
model approval and 50 passed exact citation coverage. These counts do not establish
clinical correctness. Ambiguous measurements became confident findings, unsupported
specificity survived, and condition grouping still conflicts with the Draft key.
An excluded unresolved row exposed a release-blocking issue that the headline score
would otherwise miss. The candidate remains unreleased.

All 50 jobs completed at $0.0688963, including nine probe jobs. The unchanged shared
$1 ledger now has $0.48418625 used and $0.0456 in pre-existing uncertain reservations;
this pass added no uncertain reservations. The 290-test Swift suite passed with two
optional skips; nine scorer tests, production parser checks, processor compilation
and temporary endpoint typechecking passed. This was not a device UI/release-build
test. Temporary deployment/access files were removed, live aliases and scheduled
cleanup verified, and the spreadsheet left unchanged.

Next priorities are ambiguity and unsupported specificity, reliable original-source
span references, consistent offer/plan/received semantics, and condition links.
Keep safety review separate from row scores and require a second labelled record
before considering a release.

Validation commands:

```sh
swift test
python3 scripts/test_summary_parser.py
python3 scripts/test_score_scorecard.py
```
