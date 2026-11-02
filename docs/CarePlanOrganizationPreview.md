# Care plan organization preview

Branch: `codex/care-plan-organization`, forked from released build 18 (`caf6f0bb`).
Open this worktree’s `SpeechSessionApp.xcodeproj` and select **Care Plan Preview**.
There is no separate preview section. Use **Profile → Regenerate conditions** to organize existing saved care details; the normal progress screen opens immediately. Open a condition to review its Care plan, Follow-up and Other considerations.
This uses normal cloud consent and the existing budgeted backend. It is not a new deployment.

## Behavior

Care plan contains definite self-care/treatment recommendations; Follow-up contains discrete next steps with source-backed owners; Other considerations contains conditional/declined/exploratory/background/anticipatory/already-received items. Buckets appear inside existing condition views. All retains its existing category layout. The canonical saved categories and condition links remain intact. Original titles, details and occurrences are preserved.

Rows show an instruction, date, follow-up owner when applicable, and expandable details/sources. Missing ownership is explicit. Recommendations do not gain a default Current label. Considerations cannot become next-step actions. Patient-set statuses remain available.

Audio source dates are shown as Source. Document event dates retain their original precision as Recorded. Upload-only dates say Source date unknown / Added and do not promote a document in recency ordering. Undated items sort last. Source occurrences remain individually visible.

Existing eligible generated care/follow-up items are organized during the next normal update, in batches of eight using saved original text. Each draft is independently source-checked through the existing checker, including every component of careInstruction. No keyword classifier is used. Malformed/refused responses remain technical errors. Valid source-check rejections receive one targeted repair and independent recheck. Supported entries publish as an atomically checked subset; unresolved entries remain unchanged with a visible notice and do not block condition organization. Original titles and clinical fields are never silently rewritten. Successful batches are persisted checkpoints; unchanged entries are skipped on retry. Repair request inputs omit transient draft timestamps so identical saved input and feedback retain durable request identities on retry. A stale entry or source rejects the entire batch publication. Patient-added/edited entries are not automatically rewritten.

New cloud extraction emits bucket/owner/context with the instruction, using the existing checking contract. On-device extraction also supports these optional fields; legacy reorganization runs only with cloud processing. Optional fields preserve older decoding compatibility. No global summary version reset occurs.

## Testing and limitations

No paid inference or patient data was sent during implementation. Local tests cover strict identities, malformed responses, owner shape, checking requirements and invalid quotations, rejected judgments, old decoding, date ordering, considerations excluded from next steps, restart persistence and atomic stale/core-edit rejection. These tests validate enforcement; they do not prove a model will classify every real example correctly.

The existing full Swift suite passed (385 tests, 3 skipped) before the last three targeted tests were added; the final targeted suite passed 21 tests. The generic iOS debug build passed. Review actual grouping, ownership, compact wording and source dates on the device before merging. Model accuracy, actual added latency/cost and small-screen visual QA remain device-validation items.

No merge, GitHub push, TestFlight release, model-policy change, backend deployment or budget increase is included. The unrelated pending retention changes in the original checkout are untouched.

## October 24 interaction correction

Removed the separate preview panel and preserved All’s category structure. Explicit update actions open the existing progress sheet. Care organization keeps the details stage active until checking and publication finish, rather than appearing ready while work is still in progress. No backend deployment or paid processing is needed to build this correction.

## October 24 source-check rejection correction

Inspected the existing classification and checking jobs read-only. Both completed with valid JSON. Four of eight checking decisions rejected omitted qualifiers or conflicts with unchanged original titles/statement types. The former all-supported guard incorrectly reported invalidFormat for that semantic rejection and aborted the entire batch.

Source rejection now has a distinct diagnostic. One targeted repair addresses proposed wording, followed by a fresh independent check. A rejected original title is not rewritten just to obtain support. Verified subsets save with existing stale-edit/source guards; unresolved originals remain intact and are reported. Each item is attempted once within a health-story update, avoiding repeated repair when the saved-input fingerprint changes after partial publication. No live repair inference was run during this correction. Eleven focused tests pass; device verification is still required.

## October 24 aggregate-card iteration (supersedes row-by-row migration)

The condition view now presents one derived care-plan card per source record, with Action, Follow-up and Considerations all visible. Dates and review metadata are grouped, practitioner identity is source-backed or explicitly unknown, and a single disclosure provides original details and the source record. All retains its canonical categories. Multiple clinical dates are identified rather than collapsed to an upload date.

The condition update now generates a separate non-destructive presentation instead of repeatedly reclassifying saved entries. Semantic consolidation returns exact member IDs: every input occurrence must appear once and only once. Every line and practitioner attribution requires a locally matched source quotation. A second model call independently checks support, attribution, retained qualifiers, and completeness of the aggregation. Patient-edited items cannot be merged or paraphrased. No keyword-based consolidation is introduced.

Accepted cards are cached in the existing protected sessions envelope with source, content, condition and preference fingerprints. Changed input invalidates display immediately; record deletion removes its cards. Original details, assessments, edits and condition links are never rewritten by presentation generation. Rejected cards show original wording and a notice rather than false success. Normal budgeted requests remain in use; no paid model calls or deployment were performed during implementation. A rebuilt preview and Regenerate conditions are needed to produce the new cards on the device.

### October 25: care-card validation and notice recovery

A saved classification response used factKey labels instead of item UUIDs and changed a supporting quotation. Generation now constrains memberIDs to the actual input UUIDs. Local validation reports the specific rejected invariant; one bounded targeted repair is permitted, followed by the same local validation and independent source check. Provider/network failures do not enter this repair path. No source or edit checks were relaxed.

The Conditions notice now distinguishes successful condition organization from incomplete care-plan aggregation and provides a dismiss button. Dismissal clears only the notice; it neither submits processing nor marks a card verified. Original wording remains available wherever an aggregate is absent.

Validation: six care-card tests pass, including synthetic reproductions of the observed label-as-ID and altered-quotation failures. No paid model replay was performed for this fix.

### October 25: remove quotation retyping from aggregation

The next device run still failed the exact-quotation check after repair. Care-card generation now uses the `care-card-evidence-v2` request contract: the app partitions the original source into exact contiguous passages and supplies their IDs. The model selects constrained evidence IDs instead of generating quotations. The app expands them to the original contiguous source span before local validation, independent semantic checking, and storage. Nonadjacent selected passages include intervening context; source text is never normalized or reconstructed by the model.

Existing checked cards remain reusable. New requests use a different payload and response schema, preventing old failed responses from satisfying this contract. Stored card format, original details, edit protection, full occurrence coverage and independent meaning checks remain unchanged. Invalid, missing or duplicate evidence IDs fail validation. This removes quotation transcription as a model task; it does not guarantee that a proposed plan will pass semantic review.

Eight focused tests pass, including exact Unicode/whitespace reconstruction across passage boundaries, unknown/missing/duplicate references, constrained item IDs and edited-item protection. No paid inference was run by the agent.

### October 25: protect patient wording by construction

A subsequent device run reached the patient-edit rejection. The v3 contract excludes user-added and user-edited entries from both aggregation and its independent checker. Their saved title and details are rendered directly alongside generated lines, labelled “Your wording”; generated care-instruction text cannot override them. Patient-only inputs make no aggregation requests. The source list retains all occurrences, and storage still checks the complete input for intervening edits. New fingerprints prevent older cards that included patient-written entries from being displayed alongside them twice.

Generated entries still require complete ID coverage, source evidence and independent semantic approval. A response that includes protected IDs is rejected. Regression coverage verifies protected entries are absent from model input and retained separately for presentation. No paid inference was run for this change.

### October 25: encounter-level evidence

Read-only inspection of the 23:39–23:40 UTC jobs confirmed fresh semantic rejections, including wrong passage selection, uncertain-frequency bucket disagreement, and omitted medication-review context. Each card is already scoped to one encounter, so v4 evidence uses that complete original source. The checker receives it once and references it by S1 rather than receiving repeated full quotations. This removes passage selection as a failure mode without removing independent support/completeness checking. Generation and checking now agree that uncertain frequency alone does not reclassify a recommendation. Medication-review completeness remains subject to live validation. Full Swift suite: 401 tests, three skipped, zero failures. No paid model execution by the agent.
