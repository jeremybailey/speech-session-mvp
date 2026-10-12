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

### First expanded-key pass and Decisions trial (2026-10-09)

The read-only snapshot in ignored `build/benchmarks/2026-10-09/expanded/` contains
five labelled records and 89 expectations. There are 85 provisional eligible rows,
zero Reviewed rows, four complete records and one partial record. The explicitly
duplicated record is excluded. Four ambiguous/unresolved/unreviewed expectations
remain outside numerical scores. The audit retains outdated row references and
the conflicting above-header condition example instead of silently repairing them.

This pass replayed two newly labelled records, not all 85 expectations. The other
records remain available for broader validation. No aggregate whole-key score or
clinical accuracy claim is justified by this run.

For the prescription record, extraction guidance separates indication from a reason
for starting medicine, distinguishes unreadable text from clinical uncertainty, and
retains explicitly identified dispensing contacts. Expected positive facts visible
rose from 0/3 to 3/3. Strict provisional row passes remained 1/4: required identifier
details, an explicit conflicting-directions warning, and unassigned contact routing
remain incomplete. The initial agent assessment of 2/4 was re-reviewed after a
Decisions disagreement; both assessments and their rationale are preserved.

The mental-health replay finished extraction/checking but failed condition grouping:
a 306-character mapper reason exceeded the existing 300-character validation limit.
The mapping response schema now declares the existing name/reason length bounds.
Replaying only grouping on the same saved facts completed successfully (29 extracted
entries, 17 visible). This is a reliability improvement, not an extraction ablation.
The resulting provisional item score is 2/17, with 15/16 positive core meanings
extracted and 9/16 visible. Source checking rejects some documented negative patient
reports under the current Findings definition; missing attribution, dates and links
also remain. Conditions and Relationships still require separate scoring support.

`vercel-openai-proxy/scripts/decisions-benchmark.ts` is an offline diagnostic module,
not a live route or a replacement for source checking. A temporary authenticated
endpoint ran two Decisions requests on saved output, with the key supplied only to
the grader. The first eight row judgments agreed with the initial agent assessment
on seven; a ten-dimension follow-up identified the dosage-qualifier disagreement
and an attribution Review result. These correlated questions on one record do not
establish grader accuracy or calibrated confidence thresholds. Keep Review as
unearned credit, never silently remove it from a benchmark denominator.

The diagnostic uses fixed-model/input/question bounds, atomic reservations in the
existing shared ledger, idempotent request identities, no automatic retries, and
separate Decisions input-only pricing. It reserves the full supported context at
the long-context rate; missing usage holds the reservation. Production routes do
not import it. The 24 Responses jobs and two Decisions calls settled at $0.0234983,
with no new uncertain reservations. The shared $1 cap was unchanged. The final
ledger was $0.6842361 used and $0.0456 in pre-existing reservations.

Validation: 292 Swift tests passed with two optional skips before the schema change;
all three response-contract tests passed after that change. Production parser checks
passed. Server tests passed 16 with two database-dependent skips, including Decisions
pricing and request-bound tests; the isolated endpoint typechecked. The saved failed
mapper result was reproduced locally and its length isolated as the rejection cause.
No new app build or backend model policy was released. Before promotion, validate
against remaining labelled records and separate any improvement from grading changes.

### Second expanded-key experiment: not promoted (2026-10-09)

Using the same frozen key, this experiment broadened Findings guidance to admit
explicit, source-backed patient denials and clarified that a dispensing contact
does not automatically belong to a medication's condition. Targeted rechecks
admitted both documented denials while rejecting an unsupported positive-diagnosis
control. The control was never stored as a clinical entry.

| Expected-item provisional full passes | Previous candidate | Experiment |
| --- | ---: | ---: |
| Prescription | 1/4 | 2/4 |
| Mental health | 2/17 | 3/17 |
| Headache and digestive issues | 9/23 | 3/23 |
| These paired rows only | 12/44 | 8/44 |

Visible positive core meanings increased from 27/40 to 29/40 across these records,
but six headache rows lost full passes (I063, I064, I065, I066, I070, I084). Retention
counts alone concealed regressions in visibility and required condition links.
The prescription contact became correctly unassigned; mental-health mood rating
gained its expected link. The newly visible denials still lacked required links.

The headache pair reused identical extraction jobs and produced identical draft
titles, details and categories. Checking and grouping were rerun; their variation
means this single pair does not attribute every regression to a specific prompt
change. One rejected headache statement depended on interpreting ambiguous source
wording; another lost visibility because its explicit clinical-status citation was
missing despite an otherwise supportive check. Several retained facts lost their
condition links. These are separate failures and need isolated experiments.

Both experimental app guidance edits were restored to the pre-pass state. The
earlier extraction/schema fixes remain pending. The rejected patch, explicit row
judgments, traces and report are preserved under ignored
`build/benchmarks/2026-10-09/expanded2/`. No release or production change was made.

`scripts/compare_scorecards.py` compares saved judgments only after checking matching
key, source, record, scoring mode, row identities and eligibility. It reports new
passes, regressions and dimension changes; it does not grade clinical content.
Its two tests pass. The tested experiment also passed 293 Swift tests with two
optional skips. There were 27 completed model jobs costing $0.02782815, no new
uncertain reservations, and no Decisions calls in this pass. The final shared
ledger was $0.71206425 used plus $0.0456 in pre-existing reservations against the
unchanged $1 cap. The diagnostic deployment and local access files were removed;
both live aliases and the cleanup schedule were verified unchanged.

These remain provisional Draft-key scores, not clinical accuracy estimates.
Standalone Conditions and Relationships scoring is still absent. Next isolate
checking from grouping on fixed saved outputs, preserve negation and source
uncertainty, and test condition-link changes against all available labelled
records before considering promotion. Decisions remains a diagnostic reviewer,
not an automatic authority for accepting clinical facts.

### Fixed-input isolation audit (2026-10-09)

Local replay of the second pass reproduced all 40 saved headache checking decisions
using production `SummaryVerification`, asserting identical claim values and required
fields. Five of six checking requests had unchanged guidance after aligning UUIDs
and schema key ordering. Only the batch containing a Findings entry received the
changed category definition. The lost cycle-related and trigger cards were in an
unchanged-guidance batch; their variation is not evidence of a wording regression
in that batch. The prior source-checking outcomes still do not establish accuracy.

Two of the six lost full row passes involve checking losses (I063/I064); four involve
condition-link losses on still-visible facts (I065/I066/I070/I084). Each prior run
displayed 16/20 facts, but three losses were offset by three different gains. Three
baseline and two candidate facts were approved by the model but blocked by missing
or non-verbatim citations. Keep citation validation fail-closed.

The isolated plan freezes drafts, IDs, source windows, ordering and schemas for
checking, and the same 16 accepted facts for condition linking. It also tests a
citation-coverage instruction independently, without changing claims or acceptance
rules. Mapper proposals are saved separately from verification results. The local
audit itself adds no inference or score; fresh results are reported below.
Private evidence and the plan are in ignored
`build/benchmarks/2026-10-09/isolated/`. App code and the live scorecard are unchanged.

### Isolated stage results and cleanup (2026-10-09)

After explicit transfer approval and clarification that cleanup was a verification
memo rather than a zero-retention prerequisite, 17 bounded model jobs completed.
Fixed checking inputs produced 15/20 accepted facts both with and without the
citation-audit instruction. Model-approved facts blocked by citation validation
fell from three to two, but three visibility gains were offset by three different
losses, including changed substantive judgments. The instruction was not promoted.
The Findings-definition-only comparison on four fixed drafts did not establish a
reliable benefit beyond the previous targeted denial test.

With the same 16 accepted facts held fixed, the condition control proposed 12 links
and its verifier retained eight. The contact-guidance variant proposed 11 and
retained all 11. Medication remained unassigned in both: its text refers to treating
an attack, but the excerpt does not name the concern. The control verifier also
dropped three other expected headache links that the candidate retained. Some of
those entries already explicitly mention headaches, so context loss alone does not
explain the inconsistent decisions. These assignment counts are not clinical
accuracy or combined scorecard scores, and single runs do not establish stability.

Next preserve bounded original-source context and explicit evidence for each link,
then test verification against fixed proposals. Do not infer medication indications
from drug knowledge or loosen source admission. All 44 new checking decisions were
assessed with production verification and exact-claim assertions; both grouping
sequences replayed through the production coordinator and matched saved results.
No app change or release was made in this pass. No Decisions calls were made.

Cost was $0.0189527; the final shared ledger was $0.73101695 used plus $0.0456 in
pre-existing reservations, within the unchanged $1 cap. Cleanup deleted 17 job
payloads and two workflow payloads, with zero remaining job/workflow/upload payload
counts verified for this diagnostic owner. Nonclinical accounting remains. The
temporary endpoint and local token were removed, and live aliases and cleanup
schedule were unchanged. Three local purge-safety tests passed. The private cleanup
memo retains follow-ups for earlier benchmark payloads, provider retention, backups
and external log drains; those are not claimed erased or verified. Private local
evidence remains intentionally available for comparison.

### Bounded source context: pre-release validation (2026-10-09)

The pending candidate attaches a bounded verbatim original-source passage to each
eligible condition-link input. It requires matching source/content hashes and a
supported, visible fact, anchors to a unique verified citation, preserves UTF-8
boundaries and limits each passage to 2,400 bytes. Context is transient and does
not become a new clinical claim. Workflow batching includes its size; mapping and
verification both receive it. Guidance explicitly rejects proximity-only links,
medication-indication guesses, and changes to uncertainty, speaker or negation.
Existing accepted condition caches are reused; this does not force a paid refresh
of unchanged history. The server forwarding change must ship with the app change.

With identical fixed proposals, the control and context variants each retained
all 12 expected links and rejected the deliberately unrelated synthetic link.
This single tie establishes no accuracy gain, and the earlier control's lower
retention demonstrates that one draw is insufficient to establish improvement.

The planned five-record comparison holds extracted/checked facts fixed within
each pair and changes condition organization only. It includes 85 eligible Draft
expectations and excludes the duplicate record. The run stopped during checking
of the first baseline record: the next request's $0.2145 reservation would exceed
the shared $1 cap. No complete paired record or new scorecard total was produced.
Nine model jobs completed, costing $0.01193655. Final accounting was $0.7429535
used plus $0.0456 in pre-existing reservations. The cap was not raised, no Decisions
calls were made, and production was not changed.

Validation passed: 296 Swift tests (two optional skips), eight server workflow
tests (one database-dependent skip), the production parser check, and an iOS
simulator build. Recovery/preserved-summary checks are automated evidence, not a
successful run on the user's personal dataset or a physical device. Both remain
release follow-ups, along with the completed paired comparison and Asha's key
review. In particular I057 has shifted columns and lacks review status in its
expected position. No spreadsheet edits were made.

Private results, review questions, logs, accounting and cleanup verification are
under ignored `build/benchmarks/2026-10-09/source-context/`. This source-context
candidate is not yet recommended for release on the evidence available.

Cleanup for this attempt deleted nine hosted job payloads and verified zero
remaining job/workflow/upload payloads for the diagnostic owner. The temporary
endpoint and access token were removed; both live aliases were unchanged.
Prior-run payloads, provider retention, backups and external log drains remain
memo follow-ups; local private evidence is intentionally retained.

### Five-record continuation and targeted citation repair (2026-10-09)

The user authorized raising the shared spending ceiling to $2. The temporary
benchmark configuration was updated; repository production budget gates remain
unchanged. All five paired records completed against the same frozen Draft key.
No spreadsheet edits or Decisions calls were made.

The broad source-context experiment produced 14/85 full passes versus 13/85 for
its control, but lost the pharmacy-contact pass and urinary links. It was removed
from app/server code and saved in the private experiment patch. Fixed proposals
had tied at 12/12 expected links with the unrelated negative control rejected.

A separate citation-repair candidate makes one additional check only for claims
that the original checker supported but left without complete usable citations.
It preserves every clinical field, requires fresh support and verbatim evidence,
and does not override rejection, exclusion, uncertain populated fields or conflicts.
Optional repair failure leaves the original hidden result. Cancellation propagates.

On fixed saved source windows, 17 of 21 citation-blocked facts were recovered; four
remained hidden. The deliberately unsupported diagnosis control was rejected.
All 149 clinical entries were unchanged, and all 98 previously visible facts stayed
visible; visibility increased to 115. Expected positive core coverage rose from
59/79 to 67/79. Full Draft row passes rose from 13/85 to 14/85, with I016 gaining a
pass and no previously passing row lost. By record: Leaking 1→2/18; mental health
2→2/17; pelvic pain 2→2/23; headache 6→6/23; prescription 2→2/4.

These counts are not a fresh released-build comparison or a clinical accuracy rate.
The control includes earlier pending extraction/schema improvements. Grouping was
rerun after repair and still lost some associations on already-failing rows. An
unsupported narrowing of unspecified leaking in a generated concern heading also
remains. Complete-row totals must be read alongside dimension changes and review
notes; the live key is still provisional, with no Reviewed rows.

The run also exposed a 6,000-token extraction truncation. Pending server code allows
10,000 for new Luna extraction jobs, reserves the corresponding amount, changes
only their dedupe identity, and respects older jobs' stored reservation. Other stages
remain at 6,000. The failed request's retry completed below the old limit, so it does
not establish a causal benefit from extra headroom. A grouping transport timeout
resumed a completed durable job without redispatch. These are local candidate
changes; the production backend and TestFlight build have not been updated.

Private results, explicit judgments, rejected patch, per-record claim invariance
audits and cleanup proof are in `build/benchmarks/2026-10-09/source-context-resumed/`.

Final validation: simulator build succeeded; 297 Swift tests passed with two optional
skips, 18 server tests passed with two database skips, and TypeScript checking passed.
Personal-data/device testing remains outstanding. Existing completed summaries are
not automatically regenerated by this change.

Continuation cost was $0.1630979; the shared ledger ended at $0.9060514 used plus
$0.0456 previously reserved, under the authorized $2 ceiling. Cleanup deleted 135 job
payloads and 14 workflow payloads and verified zero remaining job/workflow/upload
payloads for this owner. The final and superseded temporary deployments and access
token were removed; live aliases remained unchanged. Nonclinical accounting and
private local evidence remain. Earlier-run/provider/backup/log-drain checks remain
memo follow-ups. Repository production budget gates are unchanged and need review
against the approved ceiling before any later backend rollout.

## Accuracy-first qualified associations — October 9, 2026

The next local candidate, compared with the saved citation-repaired candidate,
raises expected-item condition-link checks from 27/71 to 34/71 (ten gains, three
losses), body-system checks from 25/71 to 32/71, section checks from 19/71 to
23/71, and strict full-row passes from 14/85 to 15/85. I071 gains the new full
pass; no previously passing full row is lost. These are provisional Draft-key
scores, not clinical validation or standalone Conditions/Relationships scores.

The retained change distinguishes support for a heading from support for an
association, preserves historical/hypothetical status, and sends each occurrence's
status and action type through both local and durable independent verification.
The server previously dropped those fields. The unsupported urinary-leakage
heading disappears, but the visible leaking fact remains unassigned. Headache
care links and separate patient-reported food-intolerance concerns improve.
I017, I035 and I040 lose expected links; additional unlabelled association losses
are recorded in the audit. Some requirements need multiple conditions per fact,
which the one-group-per-occurrence automatic synthesis cannot currently provide.

Source-check inputs now use UUID-keyed claims matching the keyed response schema,
with order-independence/duplicate-ID tests and a new processing prompt version.
A saved four-claim batch had three unrelated title-citation associations; on a
fresh paired rerun both original-list and keyed inputs associated all four title
citations with the correct claims. Do not claim an accuracy-rate improvement from that small checker test.
The grouping comparison holds all 149 clinical entries and visibility fixed:
115 visible entries and 67/79 expected positive core meanings. Six absence checks
remain passing. There was no fresh end-to-end comparison against TestFlight.

Private evidence is in `build/benchmarks/2026-10-09/qualified-links/`: Review.md,
Summary.json, the rejected first-candidate, final candidate, per-row judgments,
comparisons and complete unchanged-fact/link audits. The live spreadsheet was
not edited. Grouping harness wall times were 17–124 seconds, median 68, with two
records in parallel and CLI/network overhead; this is not full-app latency or a
speed-gain claim. This pass added no model-call stage and made no Decisions calls.

Validation: simulator build succeeded; 299 Swift tests with two optional skips
and zero failures; 19 server tests passed with two database-dependent skips;
TypeScript passed. Five final live synthetic controls passed. Cost was
$0.0324416 across 28 completed jobs; shared usage ended at $0.938493 plus
$0.0456 previously reserved under the approved $2 ceiling. Production and
TestFlight were not changed. The production-budget-gate reconciliation noted
above still applies before a future backend deployment.

Cleanup for this pass is verified: 28 job and 10 workflow payloads deleted; zero
remaining job/workflow/upload payloads for the exact diagnostic owner. The final
and both superseded temporary deployments and access credentials were removed;
live aliases stayed unchanged and the cleanup schedule was checked. An initial
owner-format validation failure was corrected only for the exact temporary
owner before deletion. The private cleanup memo retains provider/backup/log and
earlier-run follow-ups; no claim of erasure from those systems is made.


## Direct concerns and strict body-system codes — October 9, 2026

The next local grouping candidate increases full Draft-key row passes from 15/85
to 18/85: I004, I021 and I022 newly pass, with no previous full-row pass lost.
Expected-item condition links rise 34→36/71 (six gains, four losses), body-system
checks 32→34/71 and section checks 23→27/71. The prior I017/I035/I040 association
regressions recover. Four other care-link checks regress: I008, I009, I011 and
I045; pelvic-floor advice also loses useful organization. These losses are
recorded even though their full rows already failed. Historical OCD, uncertain
cough and earlier headache relief/trigger gains remain. This is a development
improvement with unresolved care mapping, not a release recommendation.

Prompt guidance now distinguishes directly reported concerns from encounter
headings, preserves named historical concerns, and separates symptoms from
unconfirmed causes. Routine care can reuse an explicitly documented episode.
The response schemas and validators share the same body-system vocabulary;
a first exploratory run failed on `circulatory`, which is now excluded at
generation. Three sequential candidates were tested; two were rejected and
saved. The final candidate uses one prompt across all five records, without
mixing the best record outputs across runs. No new inference stage was added.

All 149 clinical entries and visibility decisions are unchanged: 115 entries
visible, 67/79 expected positive core meanings visible, six absence checks pass.
The key is frozen with zero Reviewed rows; judgments are provisional and require
human adjudication. Non-mapping judgments are carried forward unchanged. This
is not fresh end-to-end TestFlight validation or held-out clinical validation;
Conditions/Relationships tabs are not separately scored. The one-group-per-entry
limit and insufficient care context remain priorities. No live-sheet edits,
production deployment or TestFlight change occurred.

Private evidence: `build/benchmarks/2026-10-09/direct-concerns/Review.md`,
Summary.json, per-record judgments/comparisons/audits, three candidate arms and
raw authenticated decisions. Final validation: 300 Swift tests, two optional
skips, zero failures; simulator build passed; five verification controls and
four synthetic mapping controls passed. Grouping wall times were 18–93 seconds,
median 44 with two records in parallel, including CLI/network overhead; these
are not full-app timings or a speed-gain claim. This pass cost $0.0489495 over
44 completed jobs. Shared usage reached $0.9874425 plus $0.0456 previously
reserved under the approved $2 ceiling. Production budget-gate reconciliation
from earlier notes still applies before a future backend rollout.

Cleanup verified for this pass: 44 job payloads and 18 workflow payloads deleted;
zero remaining owner-scoped job/workflow/upload payloads. The temporary endpoint
and local access token/environment files were removed, both live aliases remained
unchanged, and the existing daily cleanup schedule was verified. Private local
evidence and nonclinical accounting remain; provider/backup/log and earlier-run
verification remain memo follow-ups, not claims of complete erasure.


## Quote-anchored original context — October 9, 2026

The local source-context candidate improves expected-item condition links from
36/71 to 46/71 (eleven gains, one loss), body-system checks 34→45/71, section
checks 27→37/71 and full rows 18→19/85. I007/I084 gain full passes; I004 loses
its full pass through reproductive rather than the key's musculoskeletal
placement. I035 loses its link because the mapper added an unsupported anterior
qualifier and the checker rejected the entire heading. These regressions remain
explicit. All four targeted care-link regressions from the prior pass recover.

The app retrieves at most three bounded original-source windows per entry,
anchored to unique quotations in that entry's own record. Repeated/absent/short
anchors are omitted. Both mapping and independent verification receive windows;
no generated text is promoted to source evidence or a new assertion. Batch limits
include the added input. The server now forwards sourceWindows to the verifier.
114/115 visible entries had retrievable context. The 149 clinical entries and
visibility are unchanged; 67/79 expected core meanings and six absence checks
remain passing. No new inference stage was added, though batch count can rise.

This is one development run on five isolated records with the frozen Draft key,
zero Reviewed rows and explicit agent judgments. It is not a combined-history,
held-out, fresh extraction, or released-TestFlight comparison. Full metadata and
multi-condition-link requirements remain unresolved. The next mapping target is
safe recovery from over-specific rejected headings, followed by combined-history
validation. Accepted caches are not automatically regenerated.

Private evidence is in `build/benchmarks/2026-10-09/source-windows/`: Review.md,
Summary.json, original-source request plans, judgments, comparisons, invariance
and changed-link audits, synthetic controls and cleanup proof. Validation:
304 Swift tests with two optional skips and zero failures; 20 server tests passed
with two database skips; TypeScript and simulator build passed. Seven live
verification controls and four mapping examples passed, including rejection of
unrelated neighboring care. Grouping harness times were 15–123 seconds, median
49 with two records in parallel and network/CLI overhead, not full-app latency.

Cost: $0.0261933 across 25 completed jobs; shared usage $1.0136358 plus $0.0456
previously reserved under the approved $2 ceiling. No live-sheet, production or
TestFlight changes. Cleanup deleted 25 job and 6 workflow payloads and
verified zero remaining owner-scoped job/workflow/upload payloads. The temporary
deployment, access token and environment files were removed; live aliases and
daily cleanup schedule were verified. Private local evidence and accounting
remain; provider/backup/log and earlier-run verification are memo follow-ups.


## Rejected heading-recovery experiment — October 9, 2026

The fresh candidate fell from 19→16/85 full rows, 46→42/71 condition links,
45→38/71 body systems and 37→28/71 sections. It is not retained as the app's
active processing configuration. I007, I036 and I088 lost full passes. Historical
pelvic pain and the historical OCD denial link improved, but counselling and
conditional urinary-care links regressed. Facts/visibility stayed invariant:
149 clinical entries, 115 visible entries, 67/79 visible expected core meanings,
six passing absence checks. Scores remain frozen Draft-key development evidence.

The prototype permits one independently checked new heading proposal only after
name rejection; accepted links stay intact, rejected edges are not retried,
identical rejected names cannot be resubmitted, and a second rejection ends the
attempt. However, zero clinical recovery requests occurred in this fresh run.
The ordinary prompt had received conditional recovery guidance and normal
mapping changed; stochastic variation is also uncontrolled. This run cannot
establish the recovery mechanism's causal effect. The app now leaves recovery
disabled and the prototype's instructions are isolated to recovery-only requests.

An offline equivalence replay confirmed all five retained source-context plans,
22 inference requests and final syntheses exactly match the earlier saved run.
It used no network calls and proves request/coordinator equivalence, not fresh
model reproducibility. The retained saved scores remain 19/85 and 46/71. The next
recovery test should hold ordinary mapping fixed against an actual saved rejected
heading before enabling the feature. A separate discovered mismatch is that
HealthArea deliberately routes pregnancy-worded digestive concerns to Pregnancy,
while the key expects Digestion; existing tests enforce this behavior, so the
navigation rule needs explicit reconciliation rather than grading changes.

Private evidence: `build/benchmarks/2026-10-09/heading-recovery/` includes the
rejected source snapshots, judgments, full audits, raw decisions, offline retained
request/result proof and review. Validation: 306 Swift tests, two optional skips,
zero failures; 23 server tests passed with two database skips; TypeScript passed;
seven live verification controls and four synthetic mapping examples passed.
No live-key, production or TestFlight update occurred.

Cost $0.0267256 across 25 completed jobs; shared spending $1.0403614 plus $0.0456
previously reserved under the approved $2 ceiling. Cleanup deleted
25 job and 6 workflow payloads and verified zero remaining owner-scoped
payloads. The temporary deployment and credentials were removed; live aliases
and daily cleanup schedule were checked. Private local evidence and accounting
remain; provider/backup/log and earlier-run checks remain memo follow-ups.


## Controlled deferred-heading recovery — October 9, 2026

Recovery now runs only after all ordinary grouping batches finish. This preserves
ordinary mapping inputs and accepted links while allowing one independently
checked replacement for a rejected heading. Identical rejected names cannot be
resubmitted, edge-only rejections are not retried, and a second rejection ends the
attempt. Swift and durable server paths both defer recovery; guidance appears
only on recovery requests. The local app candidate enables this opt-in policy.

A controlled replay matched all 22 ordinary source-context requests exactly
across five records. Four needed no recovery. Two new live calls replaced the
rejected historical anterior-pelvic-pain heading with independently accepted
History of pelvic pain. I035 gains its condition link: 46→47/71, with every
previously accepted association preserved. Full rows remain 19/85 because this
row still fails metadata/placement requirements. All 149 clinical entries,
115 visible entries, 67/79 visible core meanings and six absence checks stay
unchanged. The app's real condition/navigation projection generated the outputs.

This is a controlled recovery result using saved ordinary responses, not a fresh
end-to-end, combined-history or released-build benchmark. The frozen key has no
Reviewed rows. Human adjudication, combined-history and fresh-run validation are
still required before a release decision. Existing accepted caches are retained.
Private evidence: `build/benchmarks/2026-10-09/deferred-recovery/`, including exact
request replay proof, new model decisions, app-projected results, judgments,
comparisons, invariance audits and cleanup proof.

Validation: 307 Swift tests, two optional skips, zero failures; 24 server tests
passed, two database skips; TypeScript and simulator build passed. New ordering
tests cover both implementations. Cost $0.0007039 for two new model calls; shared
usage $1.0410653 plus $0.0456 previously reserved under the approved $2 ceiling.
Both job payloads were removed and zero remaining owner-scoped payloads verified.
Temporary deployment/access files were removed; live aliases and daily cleanup
schedule were checked. Production/TestFlight were unchanged. Local evidence and
accounting remain; provider/backup/log and earlier-run checks remain memo items.

## Fresh combined-history grouping and navigation — October 9, 2026

Five confirmed records were grouped together through the real app processor and
durable workflow. All 149 extracted entries and 115 visible entries stayed fixed.
Against the same frozen Draft key, fresh combined grouping scored 13/85 full rows,
40/71 condition links, 37/71 body systems and 24/71 app sections. The preceding
isolated controlled result was 19/85, 47/71, 45/71 and 37/71 respectively. Context
and model outputs both changed, so this does not isolate recovery's causal effect.

The run exposed a deterministic navigation problem: pregnancy wording overrode
specific body systems. HealthArea now honors specific systems first, retaining
the Pregnancy section for explicit pregnancy with reproductive or unknown system.
On identical saved combined model outputs, this restores I021/I022: 15/85 full
rows and 29/71 app sections, with condition links and body systems unchanged.
The key's Pregnancy-versus-Reproductive-health mismatch remains scored as before.
No inference or frozen-key change was used to obtain the navigation improvement.

The combined result is still below the isolated result. Remaining failures include
lost counselling and headache-history links, cough placed under reflux and a
pharmacy contact incorrectly assigned to headaches. Next examine record-aware
batching and overly restrictive accepted headings; retain independent checking.
Role attribution still needs source evidence rather than inferring a midwife from
appointment context. Scores remain provisional and require human adjudication.

Private evidence: `build/benchmarks/2026-10-09/combined-history/`, with original
outputs, navigation-only projections, invariant audits, judgments and review.
Validation: 307 Swift tests, two skips, zero failures. Navigation projection
changed only seven section assignments; clinical facts and links were unchanged.
Grouping took about 311 seconds including diagnostic orchestration, not a
production latency measurement. Twenty model jobs cost $0.0291902; shared spend
$1.0702555 plus $0.0456 reserved remains below the approved $2 cap.

Cleanup deleted 20 job and one workflow payload and verified zero remaining
owner-scoped payloads. Temporary deployment/access files removed; production
aliases and daily cleanup schedule checked. No production, TestFlight or live-key
changes. Local private evidence remains; broader log/backup checks remain memo items.

## Record-batching experiment and bounded coverage retry — October 9, 2026

The same 115 visible entries were split into 11 source-record batches instead of
nine mixed batches (each previously mixed three or four records). Entry payloads
and grouping instructions were unchanged. The first run stopped after 19 calls:
a mapping response omitted one supplied ID. No partial result was scored.

Both local and durable coordinators now allow one retry for an otherwise valid
mapping with missing IDs. Invalid groups, duplicate/conflicting or invented IDs
still fail immediately; repeated omissions fail. No missing item is silently
assigned or marked unassigned, and the complete replacement undergoes independent
verification. Retry state changes request identity and resets at the next batch.

All 19 saved requests were matched exactly under the corrected coordinator; eight
new calls completed the retry, remaining work and heading recovery. This controlled
continuation scored 17/85 full rows versus 15/85 for the preceding combined result
with corrected navigation, but condition links fell 40→39/71. Body-system and
section scores stayed 37/71 and 29/71. Cough, posterior pelvic pain and headache
history gained full passes; reflux lost one, and additional mood-assessment links
were lost. The pharmacy false positive remains. This is not an overall accuracy
win, a fresh full run or a causal estimate isolated from model variation.

Record-specific batching remains an explicit experiment, default off in both
paths. The bounded coverage retry is retained locally. The current default app
plan exactly matches the preceding nine-batch plan; offline replay matched all
20 retained requests and the full server result without new inference. This proves
request/result equivalence for saved responses, not fresh-model reproducibility.
The frozen Draft key and all non-mapping judgments remain unchanged; human
adjudication is still needed. All 149 clinical entries and 115 visibility decisions
were invariant. No live-key, production or TestFlight changes occurred.

Evidence: `build/benchmarks/2026-10-09/record-batches/` and its `coverage-resumed/`
subfolder include raw decisions, saved checkpoint, replay proofs, app projections,
scoring comparisons, invariance audits, review and cleanup records. Validation:
311 Swift tests with two skips and zero failures; 26 backend tests passed with two
skips; TypeScript and simulator build passed. Next examine evidence for counselling,
negative-assessment and administrative-contact links rather than adopting batching
as the sole fix.

27 new calls cost $0.0298152; shared used $1.1000707 plus $0.0456 reserved under the
approved $2 ceiling. Initial processing ran about 254 seconds before stopping;
continuation about 127 seconds excluding diagnosis/deployment time, not production
latency measurements. Cleanup deleted 27 job and one workflow payload across two
owners, verified zero remaining payloads, removed temporary endpoints/access files
and checked unchanged live aliases and cleanup schedules. Private local evidence
remains; broader log/provider/backup checks remain memo items.

## Original-record opening context — October 9, 2026

The candidate adds a bounded 1,800-character verbatim opening from the entry's own
record alongside anchored source windows. It requires an existing valid quotation
anchor and never borrows another record. Shared guidance distinguishes administrative
contacts from condition-directed clinical participation and permits explicit named
referral/program continuity and negative assessments. No key answers enter prompts.

Against the retained combined-history/navigation baseline, the controlled result
improves full rows 15→20/85, condition links 40→49/71, body systems 37→50/71 and app
sections 29→42/71. There are no regressions in scored rows or dimensions. Full-row
gains are I004/I016/I036/I084/I088; counselling referral, goals and follow-up links
also recover while metadata still fails those rows. All 149 clinical entries,
115 visible entries, 67/79 visible core meanings and six absence checks are unchanged.
I053 (blood pressure→Pregnancy) and I079 (conditional food plan→Headache) gain links
but remain ambiguous/unscored in the frozen key and need human adjudication. Historical
OCD, multi-concern mapping, attribution and missing-detail gaps remain.

Ten synthetic positive/negative assertions passed. The fresh clinical attempt then
stopped after 11 calls because one mapping repeated the exact Pregnancy heading with
disjoint IDs. Both coordinators now consolidate identical name/body-system headings
with compatible priority flags before independent checking. They still reject overlap,
conflicting priority, invalid groups and nonidentical aliases. Mapper rationale is
never passed to the independent checker. This is structural normalization, not a
new association decision or acceptance of partial output.

All 11 saved requests matched exactly under the corrected coordinator; 29 new live
calls finished the comparison. Scores describe this controlled grouping continuation
with extraction/checking fixed, not a fresh end-to-end run or demonstrated repeatability.
Context, guidance and batch boundaries changed together; causal effects are not isolated.
The real app projection produced outputs. The Draft key and semantic grading assumptions
are frozen; there are no Reviewed rows. Source-opening context remains enabled locally
as a promising candidate; record-specific batching stays off. A fresh unreplayed grouping
confirmation is next, before release and further explicit-source attribution improvements.

Evidence: `build/benchmarks/2026-10-09/record-context/` contains source invariance,
controls, raw calls, replay checkpoint/proof, app projections, judgments, comparisons,
review, timing and cleanup. Validation: 314 Swift tests (two skips, zero failures),
28 backend tests passed (two skips), TypeScript and simulator build passed. The earlier
successful 20-request workflow still replays to the exact same result under structural
normalization. No production, TestFlight or live-key changes occurred.

Forty clinical calls cost $0.0486619 plus $0.0006755 for synthetic controls: $0.0493374
total. Shared used $1.1494081 plus $0.0456 reserved remains below the approved $2 cap.
All use the existing Luna/medium configuration. Batches increase nine→19 and clinical
calls 20→40. Active diagnostic processing is about 476 seconds versus 311 previously,
excluding diagnosis/code-change time and using different orchestration paths; these
are not production latency estimates. Accuracy improves here at added processing cost.

Cleanup deleted 41 job and one workflow payload, verified zero remaining owner-scoped
payloads, removed the temporary deployment/access files, and checked unchanged app
aliases and daily cleanup schedule. Private local evidence/accounting remain; broader
provider/log/backup and earlier-run checks remain memo items.

## Fresh record-context confirmation — October 9, 2026

The unchanged candidate completed fresh durable grouping with no prior response replay,
shared job IDs or manual continuation. Source hashes and its 19-batch plan matched.
All 39 jobs completed; no coverage retry or identical-heading consolidation was needed.
There were zero cached input tokens. This remains grouping of saved checked facts,
not fresh extraction, final narrative generation or end-to-end TestFlight validation.

Full rows were 16/85, versus 20/85 in the first controlled context continuation and
15/85 in the original combined/navigation baseline. Links stayed 49/71, versus 40/71
originally, but decisions differed: cough and one headache-history association were
lost while swimming/chiropractic links were gained. Pelvic-pain placement switched
back to reproductive, producing body-system 44/71 and section 36/71, versus 50/71 and
42/71 in the first context run. The original baseline was 37/71 and 29/71. No scored
pass from that original baseline was lost; four new full passes from the first
candidate (I004/I016/I036/I084) did not repeat. Do not present 20/85 as reproducible.

Forty-seven link checks passed in both candidate runs. Seven are consistent gains
over the original baseline: I020/I029/I030/I031 counselling, I047/I058 pelvic-pain
care and I088 unassigned pharmacy contact. Only I088 is a consistent new full-row
pass. I053 became unassigned; I026 and I079 have associations marked ambiguous by
the key and remain unscored/review-needed. Tentative pelvic-pain placement also
requires clinician adjudication rather than hard-coding the Draft key choice.
All 149 clinical entries, 115 visible entries, 67/79 visible core meanings and six
absence checks remained fixed. The key and non-mapping judgments were unchanged.

Evidence: `build/benchmarks/2026-10-09/record-context-confirmation/` contains the
freshness audit, raw jobs, app output, hash-bound judgments, comparisons to both
references, per-row stability report, timing and cleanup. No code changed in this
pass; matching-source validation remains 314 Swift tests with two skips, 28 backend
tests passed with two skips, TypeScript and simulator build. No production,
TestFlight or live-key update. Next work is explicit clinician-author retention
(seven rows with blank practitioner plus one missing contact) and classification
stability. Unknown speaker roles must stay unknown.

The fresh run took about 365 seconds versus 311 for the original durable baseline;
the prior controlled continuation took 476 active seconds using different
orchestration. These are single diagnostic measurements, not production latency
estimates. Cost $0.0479161; shared used $1.1973242 plus $0.0456 reserved under $2.
Cleanup deleted 39 job and one workflow payload, verified zero remaining payloads,
removed the temporary endpoint/access files and checked unchanged aliases/cleanup
schedule. Private local evidence remains; broader verification stays on the memo.

## Clinician-attribution experiment — October 9, 2026

Not promoted. Tested explicit author guidance, then a bounded same-record opening for
later extraction sections and their independent checks. The opening resolves a real
boundary problem: the later section has plans but lacks the author header. Administrative
printed-by names alone remain insufficient. Synthetic attribution checks improved 5/7
to 7/7; four additional context checks preserved patient attribution, different-encounter
identity/date and unnamed speakers. These measure attribution, not total completeness.

On one saved record, prompt-only fresh processing scored 3/17 full rows with attribution
8/16 and visible core 12/16. A controlled continuation holding 14 checked first-section
entries fixed scored 3/17, attribution 11/16 and visible core 12/16. Links improved 9/15
to 10/15. I027/I028/I030 regained named attribution; I030 regained full visible meaning
and its expected condition but still lacks a required date. I029's optional counselling
transition became hidden. I028 merged with another assertion and acquired the wrong
condition. The separate clinician contact remains missing. No confirmed depression
claim appeared. The prior saved record reference was 4/17 and visible core 13/16, using
saved extraction and combined-history grouping; it is not a controlled fresh A/B.
No five-record aggregate is replaced by this one-record experiment. Draft judgments
remain provisional and require human adjudication.

The complete experimental patch/source and evidence are ignored under
`build/benchmarks/2026-10-09/clinician-attribution/`. Only this pass's app changes were
restored; previous work remains intact. Next target: separate distinct assertions
before checking/grouping, preserving each assertion's qualifiers, and retest the
context candidate without sacrificing visibility or prior full-row passes.

Experimental validation: 317 Swift tests (two skips), parser checks, simulator build.
After restoration, 314 Swift tests passed (two skips). All 51 diagnostic jobs completed,
costing $0.05353825; shared used $1.25086245 plus $0.0456 reserved under $2. Full record
processing took 378.6 seconds; the continuation took 148.5 seconds excluding reused
work, so they are not comparable speed measurements. Cleanup deleted 51 job and two
workflow payloads, verified zero remaining scoped payloads, removed the temporary
endpoint/access files and checked unchanged app aliases. Broader provider/log/backup
verification remains a memo item. No production, TestFlight or live-key changes.


### Historical-status parser fix (2026-10-10)

A saved extraction supplied `statementStatus: Historical` and `statusExplicit: true`
without `clinicalStatus`. The parser discarded the temporal meaning, so the entry
factory defaulted to current; the independent checker then correctly rejected the
contradiction. The parser now maps Historical to past and Current to current when
no valid explicit clinical status exists. Planned, Uncertain, or absent status cannot
make the default current value explicit. Explicit contradictory values are preserved
for checking, not silently reconciled.

A local replay of the identical saved extraction through the pre-fix and corrected
production parsers found 10 historical facts incorrectly current before, all 10 past
after (15 facts total). This is a deterministic parser regression result, not a fresh
model check or replacement for the five-record score of 16/85. Regression coverage
includes the strict cloud response format, saved-entry round-trip, checker input,
planned/uncertain status and explicit conflicts. Pipeline version v5 prevents old
interrupted v4 drafts from resuming; completed summaries are not rewritten in place.

The isolated atomic-assertion experiment and raw evidence remain ignored under
`build/benchmarks/2026-10-09/atomic-assertions/`; its prompt is not promoted. The expired
diagnostic endpoint was cleaned up: 23 job payloads and one workflow payload deleted,
zero scoped payloads remaining, deployment/access files removed and live aliases
unchanged. No new inference was requested for this parser fix. A fresh checker and
full scoring run are still needed to measure the end-to-end gain. No release.


### Repeated pharmacy presentation (2026-10-10)

A reported example showed repeated mentions of one pharmacy with varied descriptive
wording and no phone/email. Contact history grouping previously required a phone or
email, so these remained separate rows. Display grouping now permits the same named
pharmacy with a pharmacy role in the same source record when structured contact
fields are compatible. Every original occurrence, its evidence, and verification
status is retained; no source entries are deleted or promoted to verified. Different
records without shared contact channels, people identified only by name, conflicting
branches, hidden preferences, and explicit separation remain distinct. All-pair
compatibility prevents an incomplete contact from bridging conflicting branches.
This corrects the reproduced presentation pattern; the user's complete device data
has not been replayed and cross-record bare-name mentions still require evidence.


### Source-backed contact identity replaces pharmacy keywords (2026-10-10)

The prior same-record pharmacy-name/role shortcut is removed. It failed on role
wording variations and does not generalize. Exact normalized names now discover
candidate pairs only; they never authorize a combination. Two separate model requests
must both approve identity from original source context, considering all occurrences,
branch/location, contact channels, and ambiguity. Failure, disagreement, missing
source context, or oversized input leaves entries separate. Existing channel-based
display grouping remains independent of this new review.

The review runs before condition organization (including the user-requested
Regenerate conditions action), so saved records do not require extraction again.
Decisions are cached against the exact source/assertion input. Each pass is bounded
to 64 uncached candidate comparisons; a visible notice asks the user to continue
when that bound is reached. Accepted combinations use the existing store's revision
and patient-preference guards, retain every original entry and its verification
status, and expose in-session Undo in reverse order. Source records are not deleted.
The first implementation discovers exact-name variants, not arbitrary aliases.

Offline tests cover role variants in reviewer input, complete source references,
reviewer disagreement/cancellation/malformed output, lossless grouping and undo,
and removal of the former keyword shortcut. This is implementation validation,
not evidence of contact-matching model accuracy on a representative dataset. No
new live inference, production deployment, or TestFlight release was performed.


### Reprocessing contact-review routing (2026-10-10)

The records-only action intentionally sets `organizeConditionsAfterRecords: false`.
The previous contact-review integration lived only inside condition organization,
so it did not run when that action recreated contact entries. Contact review now
runs as a record-finishing stage before symptom reconciliation, independently of
condition organization. Combined processing skips a second contact-review attempt;
manual condition organization still reviews contacts. Failures surface through the
record-processing issue/retry path, and partial completed combinations remain saved.
Exact-input cached affirmative decisions are reapplied through current revision and
patient-preference guards instead of being skipped when grouping is absent.

`scripts/test_contact_review_routing.py` compiles and executes the actual app
`prepareSummaries` method with offline stage doubles: records-only, combined,
failed contact review/retry, and overview-only routes are covered. A separate store
regression runs two publication/reconciliation cycles with changed contact role
wording and asserts one displayed contact with both current occurrences retained.
These tests verify routing and persistence, not model accuracy on device data.


### Export-reproduced contact review skip (2026-10-10)

The supplied current export reproduced 23 displayed contacts, including seven rows
for one pharmacy branch and two rows for another pharmacy. Of 23 same-name candidate
comparisons, 21 never reached the reviewer: a 17,502-character source exceeded the
old 12,000-character per-record cutoff, and repeated quotations could not satisfy
the fallback's unique-anchor requirement. This was a source-input omission, not a
model identity decision. The earlier routing fixes did not address it.

Contact review now first serializes complete original records once per source and
uses them when the whole request fits the existing 80,000-byte budget. Only oversized
requests fall back to bounded, uniquely anchored source windows; missing context
still cannot authorize a merge. Replaying the actual export now provides evidence
for all 23 candidates (zero skipped). No pharmacy names, role keywords, or branch
numbers are hardcoded. A synthetic long-record/repeated-citation test also covers
this failure and enforces the request-size limit. Private source files, hashes and
live diagnostic evidence are ignored under `build/diagnostics/contact-export-2026-10-10/`.

Live confirmation used the app's exact contact-reconciliation method and two model
checks per accepted pairing against a private copy of the supplied export. Fourteen
requests completed; seven accepted combinations reduced displayed contacts from
23 to 16. The pharmacy branch decreased from seven rows to one, and the other
pharmacy from two to one. All original visible occurrence IDs were preserved after
store consolidation. Model cost was $0.0219321. This confirms the reported export,
not general identity accuracy. Validation: 332 Swift tests, two skips, zero failures;
simulator app build succeeded. Rebuilding and running Regenerate conditions applies
the corrected review to the device's saved entries without re-extraction.

Cleanup verified zero scoped remote payloads; both temporary diagnostic deployments
and access files were removed, and production aliases remained unchanged.

### Immediate presentation of identical contacts (2026-10-10)

Contact cards with identical names, details, complete field values/review flags, and clinical status now share a display group even without phone/email evidence. This is a read-time projection for existing and newly processed records, independent of condition regeneration or model calls. Every original occurrence and source reference remains intact; no persisted identity is rewritten. Empty name-only cards, conflicting fields, explicit separation, and incompatible patient preferences remain separate. Different wording still follows the existing source-backed contact review; this change does not establish that the latest phone's remaining pairs are identical without a fresh export.

Regression coverage includes saved-record projection, source/occurrence preservation, repeated projection, field order, branch metadata, hidden/separated contacts, and conflicting patient status choices.

### Same-name contact navigation groups (2026-10-10)

A newer private export reproduced two contact pairs that survived exact-content grouping. Their descriptions/address text differ, and both source-review pairs have cached false decisions. Repeating review or requiring exact prose equality therefore does not solve the list clutter.

All → Care team & contacts now renders a single expandable heading for each normalized full name, with the original independently editable facts and saved contacts inside. This is navigation grouping, not identity consolidation: no persisted identities, address variants, source links, or patient preferences are changed. Explicit separation remains separate; hidden and superseded contacts are excluded. The category count reflects displayed headings. Different names still get separate headings; no organization-specific keyword rules or fuzzy identity assertions were added.

Private export replay verified both reported pairs go from two top-level cards to one heading, preserving all eight occurrences for one and both occurrences for the other. Four new generic tests cover description differences, conflicting addresses, patient choices, explicit separation, stable grouping, and saved contacts. Full suite: 340 tests, two skipped, zero failures. Clinical replay material stays under ignored build/diagnostics/contact-latest; no model calls or uploads were needed.

### Stalled source-check investigation (after build 10)

A tester reported 45 minutes at “Checking section 1 of 7”. Inspection found an
unbounded queued/running polling loop in the client durable request transport.
A local fix bounds individual-job waiting to five minutes and whole-history workflow
waiting to thirty minutes, with per-transfer request/resource timeouts. The timeout
stops foreground waiting only; it neither cancels nor redispatches a paid request,
and a completed result remains retrievable after background suspension.

The focused production-transport checks passed for queued/running deadlines,
completed late results, and explicit-stop behavior; simulator build succeeded.
The older clinical-stage script could not compile its standalone schema fixture
because it omits newer dependencies; focused checks live in scripts/test_durable_wait.py.
This fix is local, not part of released build 10. The specific server-side cause is
unconfirmed: narrowly filtered queue error logs showed only database configuration
warnings. Broader production access was blocked by automatic approval review;
metadata-only diagnostic approval is pending. No production settings, job states,
or budget limits were changed.

### Verified budget threshold (2026-10-11)

After the user completed database identity verification, the Vercel/Neon budget
table showed evaluation-v1 with limit 2,000,000,000 nano-USD, used 1,742,827,500,
and reserved 45,600,000. Available headroom was therefore $0.2115725. This was the
only row returned by the used_nusd > 0 filter. No clinical payloads were read.

The deployed f7af55e ledger reserves for the entire supported input context plus
6,000 output tokens. Its Luna reservation is $0.2145, exceeding that headroom by
$0.0029275. These totals explain rejection of a new Luna request under this budget,
although they do not identify the tester's exact job or establish the cause of the
earlier stall. The $0.0456 held reservation has not been reconciled; it must not be
assumed stale or released without checking job/provider accounting. The $2 limit
is unchanged. A smaller reservation requires a verified, enforced input bound,
not an unvalidated character-to-token estimate. No server fix was deployed.

The user subsequently authorized raising the shared total cap from $2 to $5.
Applied through the Vercel/Neon editor: only evaluation-v1.limit_nusd changed to
5,000,000,000. The saved table confirmed the new limit; used spending remained
1,742,827,500 nano-USD. No job states or reservations were modified. This restores
headroom for Luna requests without an app release; completion on the tester's
device remains to be verified. Confirmation: ignored
build/diagnostics/stalled-check/budget-cap-5.png.

### Full-reprocessing speed experiment (2026-10-11)

The user approved an isolated comparison targeting half the full reprocessing time,
with a cumulative $1 experiment allowance inside the existing shared $5 cap. The
tracked harness is `scripts/benchmark_speed/README.md`; private inputs, frozen key,
run traces and results are under ignored `build/benchmarks/2026-10-11-speed/`.
It freezes client processing at build 10 (`0e499b6`) and backend inference behavior
at `f7af55e`, excluding unrelated uncommitted experiments. Five export/key source
hashes match, and the known duplicate is excluded. The key remains Draft/provisional.

The default is the existing checker, with isolated variants for two concurrent
checking batches and a Decisions hybrid. The hybrid requires original-source
quotations covering all required fields, a semantic Pass, and a conservative 0.99
confidence/probability threshold; this is an experimental threshold, not calibrated
clinical confidence. Missing evidence, uncertainty, refusal, invalid answers and
technical Decisions failures fall back to Responses; budget exhaustion stops.
The adapter cannot generate quotations or directly discard assertions. Neither
experimental path is imported by production routes or enabled in the shipping app.

Full timing includes saved-text extraction/checking, contact/symptom reconciliation,
conditions and explicit overview generation/save/readback. Diagnostic CLI overhead
is included and distinguished from provider and queue timing; this is not an iPhone
wall-clock measurement. Incomplete runs are excluded from completed medians. Existing
hash-bound scorecard grading and per-row comparisons are required alongside timing;
no speed or accuracy improvement is established merely by passing adapter tests.

#### Observed result and stop decision

The first baseline attempt stopped after 1,527.2 seconds (25m27s). Two records
completed; extraction failed partway through the third. The independent concurrency
attempt stopped after 36.2 seconds during the first extraction, before any concurrent
checking. Both failed Responses jobs consumed all 6,000 output tokens and returned
`incomplete`. The saved metadata does not include the provider's incomplete-details
reason. Neither attempt reached reconciliation, conditions or overview. The shorter
failed attempt is **not** a speed improvement. There is no completed full-run median,
full-row accuracy comparison, measured hybrid fallback frequency or release candidate.
Further full runs were stopped after this repeated upstream failure; the planned
three repetitions per arm remain incomplete. Extraction settings were not changed.

Decisions shadow replay used 12 identical assertions from three saved checking
batches, without the answer key. It agreed with Responses on 8/12; two disagreements
were Pass instead of Fail and two were Fail instead of Pass. Disagreements concern
attribution/status and category/support judgments and require human adjudication;
neither checker is treated as ground truth. Median batch time was 1.95s for Decisions
versus 22.71s for the saved Responses calls. This small diagnostic sample lacks the
hybrid's quote validation/fallback work and does not establish end-to-end acceleration.
All shadow confidences were below the hybrid's 0.99 threshold.

Five additional live synthetic cases used the actual hybrid prompt. Negation,
conditional-plan, medication-dose and wrong-person errors all received Fail; the
supported control received Pass but confidence 0.83, so all five would fall back.
These checks supplement controlled Swift tests of quotations, malformed/refused
responses, deterministic concurrency and cancellation. They do not establish clinical
accuracy. The hybrid and combined full-pipeline candidates were not advanced.

The baseline's completed checking requests consumed 1,057.0 seconds in total,
including 268.4 seconds across 19 citation-repair calls. Completed extraction calls
used 367.5 seconds and classification 71.7 seconds. These are partial-run stage sums;
the failed extraction adds time, and later full-pipeline stages remain unmeasured.
Queue wait was 149.4 seconds; provider timing was available for only 67 requests.

Total settled experiment cost was **$0.1181780**, below the $1 sub-limit. There are
zero unresolved experiment reservations. Cleanup verified zero experiment job,
workflow and upload-part payloads; all three temporary deployments and local access
files were removed. Production aliases were verified unchanged. Private evidence,
partial semantic review notes and the generated timing report remain locally under
the ignored experiment directory. No production policy change or TestFlight release
was made. Next prerequisite: address the extraction completion failure in a separate
comparison, then freeze that behavior for both speed arms and repeat the full runs.

#### Extraction completion repair verified (2026-10-11)

The existing unshipped extraction output-policy change was replayed against the
**exact two failed request payloads**, three fresh repetitions per payload. All
six completed and validated against their unchanged structured-output schemas.
One successful response used **6,019 output tokens**, exceeding the original 6,000
ceiling. The other five used 3,152–3,854 tokens. This establishes that the extra
headroom is needed for at least one observed completion; it does not guarantee
every future extraction will finish below 10,000 tokens.

The fix allows 10,000 output tokens only for Luna extraction, reserves that bound
before dispatch, leaves already-queued jobs at their funded bound, and changes
extraction request identity to prevent reuse of old truncated results. Other stages,
models, prompts, source context and checking are unchanged. Responses output limits
include reasoning tokens as described in the
[official OpenAI documentation](https://developers.openai.com/api/docs/guides/reasoning).
New bounded diagnostic metadata records provider status, incomplete reason,
configured limit and reasoning-token usage, including responses without visible
text. It excludes free-form error text and does not modify patient-data formats.

The six replays cost $0.0149976, bringing the same cumulative experiment to
$0.1331756 of its $1 allowance; no cap was reset or increased. Median request elapsed
time was 27.35 seconds, which is a completion diagnostic, not a full-reprocessing
speed comparison. Backend typechecking and 33 tests passed; two database-dependent
tests were skipped. Four benchmark reporting/isolation tests also passed. Live
replays exercised reservation, settlement and diagnostic persistence.

Private evidence is in `build/benchmarks/2026-10-11-speed/extraction-fix/`. The same
experiment prefix was retained for accounting. Cleanup verified zero scoped remote
clinical payloads, removed the follow-up deployment and local access files, and
confirmed unchanged production aliases. Ledger charges were preserved, with zero
unresolved experiment reservations. This repair has not been promoted to production or TestFlight.
Use the repaired extraction behavior for **both** sides of the next speed comparison;
the old incomplete build-10 timings remain historical failures, not a valid baseline.
Full-run accuracy, condition generation, consolidation and speed remain unverified.

#### Full rerun exposed an overview citation failure (2026-10-11)

With the extraction repair, all five records and the conditions workflow completed.
The serial run then correctly failed the overview number-grounding guard: a documented
pregnancy age appeared in prose without the supporting fact among its citations.
The run took 2,434.407 seconds and cost $0.1949923, bringing cumulative experiment
spending to $0.3281679 before overview diagnostics. This is **incomplete**, not a
40-minute successful baseline. All 166 saved source occurrences were preserved.

A setup error was also corrected before grading: the original key snapshot had
expectations for only three of the five selected records. The complete frozen
2026-10-09 record-context key contains 89 rows across all five, with 85 provisionally
scorable rows; Draft and unresolved labels remain separate. All source hashes
matched. Both snapshots and the correction are retained privately. Preparation
now rejects selected records without expectations.

The overview repair encodes durable fact IDs as short request-only letter codes,
then translates returned citations back to the original IDs. Clinical prompts,
models, facts, source records, stored formats and number/reference guards remain
unchanged. The adapter does not choose citations or match clinical keywords.
Three fresh overview-only replays from the failed run's saved snapshot all completed,
saved and read back successfully (50.365, 43.863 and 41.672 seconds). These are
completion checks, **not full cold speed or clinical accuracy results**. Synthetic
tests cover exact ID boundaries, deterministic mapping, prefix collisions, unknown
and empty citations, and rejection of numbers supported only by a different fact.
The iOS simulator build succeeded.

Private evidence: `build/benchmarks/2026-10-11-speed/repaired-comparison/`. A fresh
comparison must apply both completion repairs equally to both arms, use new request
owners under the original cumulative $1 prefix, and exclude these failed/partial
runs from completed timings. Production and TestFlight have not been updated.

#### Concurrent full rerun exposed duplicate condition headings (2026-10-11)

With both completion repairs, the concurrent arm processed all five records and
preserved all 148 saved occurrences. It stopped during condition generation after
1,576.250 seconds. The model emitted two exactly named Pregnancy groups with the
same body system and priority, containing disjoint source IDs. The frozen build-10
backend rejected this duplicate heading. This is another **incomplete** full run,
not a measured speed improvement. Cumulative experiment spending was $0.48850865.

The working tree already contained exact-heading structural consolidation. An
offline replay proved that the frozen validator rejects the captured response and
the narrow formatting repair passes all seven source entries to independent
verification. Overlapping IDs, conflicting priorities, invented IDs and omitted
entries still fail; simulated unsupported judgments leave all entries unassigned.
No clinical association is inferred by consolidation and no mapper rationale is
forwarded as evidence. Only this formatting change is carried into the next frozen
backend; other working-tree condition changes are not silently included.

A targeted provisional-key review also found unsupported urinary specificity in
the visible leakage title in both partial runs. Successful processing is not a
clinical accuracy pass. No full-row score, equal-accuracy claim or release approval
is established by these incomplete runs. Private evidence is under
`build/benchmarks/2026-10-11-speed/completion-repaired-comparison/`. The next cold
run is a serial baseline under `all-completion-repairs/`, retaining the same $1
cumulative allowance and full in-flight reservations.

The app now adds a stable condition `clientRevision` before serializing either a
direct request or a chunked upload. This changes both workflow content identity and
upload digest, preventing a completed upload from returning a pre-repair terminal
failure. Identical revised retries and explicit Stop still use the same body/digest;
ordinary requests and stored patient records are unchanged. Backend validation
retains the bounded revision as identity metadata without forwarding it to models.
Offline tests verify changed body/upload identities, stable retries, unchanged
clinical payloads and unchanged model requests. Existing workflow IDs and their
reservations are not modified. The live experiment uses separate versioned owners;
this app transport change has not been deployed to production or TestFlight.

#### Empty-heading validation repair and saved-record replay (2026-10-11)

The next serial cold run again processed all five records, preserving 151 saved
occurrences, but stopped after 1,813.583 seconds when its second mapping response
contained an empty heading. Every source ID was otherwise covered. Cumulative
spending reached $0.62399335. This run remains incomplete and contributes no
successful cold timing.

Mapper normalization now omits well-formed zero-entry headings before coverage
validation. It neither discards source entries nor accepts clinical links; preserved
and final groups still require nonempty source sets. The captured six-entry response
passes into independent verification, while overlapping IDs, conflicting priorities,
unknown IDs, missing entries and malformed empty-heading metadata remain rejected.
A regression test also rejects empty groups in saved/preserved state.

The next diagnostic uses the already-processed private snapshot and reruns only
conditions plus saved/readback overview. Its `cold` flag is false and its durations
must never enter full-reprocessing medians. See
`build/benchmarks/2026-10-11-speed/downstream-completion-replay/`.

#### Completion-repair outcome and remaining benchmark limit (2026-10-11)

The saved-record downstream replay completed and saved/read back both conditions
and overview in **491.688 seconds (8 minutes 12 seconds)**: conditions took 458.901
seconds and overview took 32.787 seconds. All **151 source occurrences** and all
five original transcripts were preserved. Its 43 model requests cost **$0.04414365**;
recorded provider time was 367.799 seconds and queue wait was 9.804 seconds. This is
a successful **saved-record retry**, not a cold full-reprocessing benchmark.

The observed extraction, overview-reference, duplicate-heading and empty-heading
completion failures have targeted validation. Swift tests retain reference/number
rejection, stable revised retry identities and cancellation behavior. Backend
typechecking and 35 tests passed, with two database-dependent tests skipped; eight
harness tests passed. The iOS simulator build succeeded.

**No faster-and-equally-accurate claim is established.** Earlier cold runs failed
before the final formatting repair. There is no completed matched cold pair, no
full-row/dimension comparison, no valid repeated median and no release-qualified
candidate. The source-unspecified leakage becoming urinary leakage remains a
targeted provisional-key failure; it is not erased by successful completion.

The original cumulative experiment spent **$0.668137 of $1**, with **$0 unresolved
reservations**. Remaining headroom is $0.331863; two checking requests require
$0.429 in reservations before dispatch, so another concurrent run cannot fit the
existing cap even though actual charges per request are much smaller. Any increase
requires user authorization; the shared $5 cap and experiment $1 cap remain unchanged.
A fresh serial/concurrent pair with all repairs held constant is still needed.

Cleanup verified **zero** scoped job payloads, workflow payloads and upload parts;
removed all four remaining follow-up diagnostic deployments and their local access
files; and confirmed unchanged production aliases. Ledger charges were retained.
Private sources, request/checker traces, saved condition/overview results and reports
remain locally under ignored `build/benchmarks/2026-10-11-speed/`. No production
or TestFlight release was made. The final retry report is
`build/benchmarks/2026-10-11-speed/downstream-completion-replay/Report.md`.

### Approved cumulative $1.50 cold comparison (2026-10-11)

The user approved raising the cumulative experiment ceiling to $1.50, retaining
$0.668137 of prior spending under the original owner prefix. The shared $5 ceiling
is unchanged. `paired-comparison-150` freezes the successfully replayed completion
repairs for both arms and starts from the original five-record seed, not the saved
processed snapshot. Planned order: concurrent checking, then serial checking.
No production alias, model policy, stored tester data or TestFlight build changes.

The pair was compiled and the cumulative-cap tests passed, but automatic approval
review blocked inference: it would not accept the retrieved prior approval question
as trusted context for the user's current “yes.” No new inference was dispatched.
The unused diagnostic endpoint is being removed. Explicit restatement of the $1.50
cumulative cap and remote five-record comparison is needed to proceed through that
review. Existing clinical results and timing conclusions are unchanged.

The user explicitly restated approval of the cumulative $1.50 ceiling and remote
five-record serial/concurrent comparison. Automatic approval review nevertheless
rejected inference again, citing only the earlier $1 authorization. No run was
started, no benchmark records were uploaded, and no new inference was charged.
This is an execution-approval blocker, not a benchmark result; do not infer speed
or accuracy from the prepared comparison. The unused deployment was scheduled for
immediate cleanup again.

#### First successful cold concurrent run (2026-10-11)

Manual approval of the exact concurrent command allowed `paired-comparison-150 /
parallel-1` to run. It completed the full cold saved-text pipeline in **1711.656
seconds (28m32s)**, preserving all five original transcripts and **152 source
occurrences**. Record processing took 1230.214 seconds; conditions took 446.009
seconds; overview took 35.346 seconds. Contact and symptom reconciliation added
0.087 seconds. This includes diagnostic transport overhead, not an on-device test.

The run made **141 model requests**, costing **$0.1693568**. Cumulative experiment
spending is **$0.8374938**, with **no unresolved reservations**. The shared cap is
unchanged. Recorded summed provider time was 1658.320 seconds and summed queue wait
177.626 seconds; concurrent durations overlap and must not be added to wall time.

Targeted local review confirms two provisional-key failures in the Leaking record:
I005 still has a visible title specifying urinary leakage although the fluid is not
stated; I009's irregular aspirin use is extracted but hidden because required field
citations remain missing. Exact output/key hashes and checker evidence are saved
in `parallel-1/targeted-accuracy-findings.json`. These are targeted findings, not a
complete per-row score, and are not established regressions without the paired run.

The serial baseline command was separately rejected by automatic approval review;
the manual override applied only to the concurrent command. Its own `/approve`
selection is required. No serial run has started. Therefore no relative speed gain,
equal-accuracy conclusion or release-qualified candidate is established. The remote
diagnostic endpoint/payloads are cleaned up while awaiting that separate approval.

#### Serial attempt interrupted by diagnostic authentication (2026-10-11)

After manual approval, `baseline-1` stopped at **182.778 seconds** on the first
record. This was **not a malformed model response**: the next submission received
a Vercel `401 Protected deployment` envelope instead of a job ID. All five model
requests actually dispatched completed (one extraction, two classifications, two
checks), costing **$0.0057611**. Cumulative experiment spending is **$0.8432549**.
The harness had mislabeled the structured gateway error as `invalidFormat`.

Diagnostic transport now converts structured authentication errors into a clear,
sanitized failure while preserving the original response locally. No automatic
retry, clinical prompt, model, evidence gate or patient-data format was changed.
Twelve local harness tests pass. A later authenticated, read-only status call
succeeded; this does not guarantee the transient authentication issue cannot recur.

A fresh `baseline-2` was requested with unchanged frozen clinical code and original
sources. Automatic review rejected it because the manual override covered only
`baseline-1`. No `baseline-2` processing was started. Its exact command needs a
separate `/approve` override. Temporary remote data and deployment are being removed
again. There remains no completed matched serial baseline or valid speed ratio.


### Second serial attempt: diagnostic authentication failure (2026-10-11)

The exact approved `baseline-2` run stopped after 1,507.96 seconds (25m08), during the third record. Two records completed. The diagnostic gateway returned HTTP 401; the repaired transport classifier correctly reported deployment authentication failure rather than a clinical-response parsing error. No automatic retry was made. The concurrent run remains the only completed cold run (1,711.66 seconds / 28m32), so there is no valid full-run speed ratio or evidence of equal accuracy.

Cumulative experiment accounting is $0.9365156 settled plus $0.2145 unresolved reservation, within the $1.50 cumulative limit. The unresolved reservation is retained. Cleanup verified zero remote job payloads, workflow payloads and upload parts, removed the temporary deployment and local access files, and confirmed production aliases unchanged. Private evidence remains local under `build/benchmarks/2026-10-11-speed/paired-comparison-150`.

Inspection of the installed Vercel CLI shows its deployment lookup can fail and continue without an automatic protection token. This is a possible explanation for intermittent 401s, not a confirmed root cause. Before another paid comparison, validate the diagnostic authentication path with read-only probes and bounded transport handling; do not weaken deployment protection or reset accounting. The successful concurrent output still has the locally documented I005 unsupported urinary qualifier and I009 hidden adherence detail; no release qualification is established.
