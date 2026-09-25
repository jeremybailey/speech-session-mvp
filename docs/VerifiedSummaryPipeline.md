# Verified summary pipeline

Implemented 2026-09-18. The patient-facing projection defaults to verified-only. Manual entries and edits are explicitly patient-authored and remain visible; model output requires a source-bound, content-bound assessment. Automated support is not patient verification or clinical confirmation.

## Flow

1. Fetch overlapping original text windows and related category assertions (comparison only).
2. Generate typed draft facts. Persist drafts separately from published entries.
3. Independently check every populated field, requiring exact original-source citations. Reject missing/invented citations, contaminated contact fields, unsupported interpretations and wrong categories.
4. Independently check corrections and omitted-fact additions once more. There is no unbounded correction loop.
5. Publish a whole record atomically. Source changes, run replacement and concurrent patient edits block publication. Previous checked entries survive a failed/cancelled run. Successful empty output is valid.
6. Compare candidate symptoms with original context and a second equivalence check before linking. Clinical event categories retain stricter local matching. Conflicting patient choices and Undo exclusions retain separate items.

The overview remains a deterministic composition of the accepted projection and patient status choices, rather than another unconstrained AI narrative. PDF export and Original record summaries use the same accepted projection. Original files remain available regardless of admission.

## Regeneration and repair

The story Actions menu regenerates all records; the Original record Actions menu regenerates that record. Both bypass extraction caching and use the selected processing mode. Cloud processing uses existing consent; unavailable on-device processing never silently changes provider. Automatic repair runs when records need the new pipeline, resumes incomplete records after relaunch, and does not loop endlessly on a failed record in the same view session.

Processing stages, draft snapshots, source/content fingerprints, per-field citations, admission decisions, prior entry revisions and duplicate decisions persist locally. Existing generated entries await checking; they remain accessible in the original-record detail but are excluded from the story and PDF. Source-only details can be edited and added explicitly, using the existing editor; Cancel does not add them.

## Verification evidence and remaining external validation

Synthetic tests exercise citation coverage, contamination rejection, content/source invalidation, atomic publication, superseded identity handling, empty output, failed re-verification, bounded correction, reload and concurrent edits. Existing deduplication tests cover clinical distinctions, preferences and Undo. The 500-record/10,000-verified-occurrence fixture is exercised as well.

These tests validate software behavior with controlled verifier decisions. They are not evidence of clinical accuracy of live model responses. Clinician-reviewed source/expected-output fixtures and patient testing remain release acceptance work; no claim of clinical certification is made. Production cloud and Apple Intelligence responses require evaluation on those consented fixtures. No patient records were sent to a model during development checks.

## Checker revision 8

The local gate now shares citations between exactly identical mirrored values (for example structured dose and the Dose display field), canonicalizes field identifier formatting, and resolves whitespace-only differences back to the actual original excerpt. Numeric, negation and punctuation differences remain significant. Conflicting repeated fields still fail validation. A model-supported assertion rejected by local citation validation receives the second checking pass with precise feedback. The final explanation reports the local failure, never the model's incompatible positive explanation. Successful unchanged regeneration is distinguished from an unmatched superseded assertion. Revision 7 records are eligible for repair or manual regeneration.

## Checker revision 9

Medication and contact drafts can retain a supported standalone identity when optional fields are unclear. The independent checker must explicitly approve that core and provide original-source citations; the reduced draft then undergoes the second checking pass before publication. Uncertain or uncited populated fields are removed from the proposed correction and recorded in omittedFields. Other clinical categories cannot use this reduction, and contradictory approval with explicit field uncertainty cannot publish. This prevents optional address/date issues or ambiguous printed prescription options from automatically discarding an otherwise supported identity, without guessing missing instructions. Revision 8 records become eligible for rechecking.

Extraction and checking distinguish prescription from administration, do not infer a prescriber from a multi-provider letterhead, and treat OCR of handwritten selections and ambiguous dates conservatively. The pipeline still checks extracted text, not the source image; image-level selection interpretation remains a limitation. Controlled regression fixtures cover partial medication/contact acceptance, mandatory rechecking, and rejected contradictory decisions. The editor suppresses duplicate mirrored Details inputs.

## Actionable processing failures

Technical failures now have distinct explanations for missing, duplicate or mismatched checker decisions, unreadable output, response limits, premature stops, authorization, service availability and connectivity. They do not imply that patient information is unsupported. A persistent inline message identifies the affected record and processing stage, explains what was saved, and provides recovery instructions. The original record is directly accessible from the story message. Retry unfinished work retains the remaining record IDs for the current app session and skips records already published successfully. Duplicate-check failures can retry that stage without regenerating records. An earlier record failure no longer gets overwritten by a later duplicate-check failure. Pending run stages still provide restart recovery; the detailed inline message and retry selection are in-memory.

## Checker revision 10: provider completeness

A local inventory detects explicit Dr headings and MD report/signature lines in the full original text before chunked summarization. Provider blocks stop at patient demographics, report sections and other provider headings; signatories retain only their own source line. Each detected block receives separate contact extraction and verification, with a name-only unapproved draft when extraction omits the name. No detection alone grants admission. Each candidate ends with a supported entry or a retained source-only entry and explanation; technical failures leave the record incomplete. Existing identity consolidation and patient preferences still apply after publication.

Contact corrections reuse the original draft occurrence ID and undergo the existing single re-verification cycle. A failed finding cannot suppress a contact. Optional metadata is not required to retain a supported name, and reporting/ordering roles cannot be inferred from a header. Revision 9 records are eligible for repair. The detector is intentionally limited to explicit provider-name patterns, not a guarantee of recognizing every international name/credential/layout; remaining contacts still use normal AI extraction. Anonymized report fixtures cover header/signatory separation, corporate versus provider versus patient phone boundaries, repeated blocks and mandatory source checking. No real patient document was submitted to a model for these tests.

## Recovery from incomplete checker responses

Verification starts with at most four cloud assertions or one on-device assertion per batch. Missing, duplicated, mismatched, malformed or truncated decisions trigger bounded batch splitting, followed by one retry at single-assertion size. Only fully parsed batches contribute decisions or corrections. Successful batches are not repeated; authorization and connectivity failures do not trigger this splitting policy. Cancellation exits immediately. Exhausted retries retain the previous published record and report that individual-detail recovery also failed. This is response-format recovery within a checking pass, not an additional clinical correction cycle. Final checking omits the unused correction schema to reduce response/context demands. Controlled tests reproduce repeated missing decisions, truncation, individual recovery, rejection preservation, exhaustion, empty batches, cancellation and authorization errors. Live model completion rates remain to be measured on consented records.

## Checker revision 11: independently verified contact fields

Contact detection remains a candidate inventory; it no longer restricts verification to adjacent text. The original page provides context for letterhead/footer relationships disrupted by OCR, while the checker must explicitly establish provider/clinic affiliation and exclude patient contact data. The contact name and each populated optional field are drafted and checked separately. Deterministic assembly includes only independently accepted, nonconflicting field values and preserves their citations. A rejected specialty cannot veto an accepted name/phone/address. Omitted field labels are recorded with an explanation in the existing editor. An unsupported identity remains source-only even if an optional field was approved. Prior unchanged, source-checked generated fields are included as candidates for fresh checking, never as evidence, to avoid losing them merely because a new extraction is sparse.

Contact field checks do not infer specialty from credentials or rename a printed role. They use the existing technical retry policy and require a decision for every field draft. No additional clinical correction cycle or navigation is introduced. Anonymized tests model the interleaved prescription header, patient name, and distant clinic footer, role rejection with other fields preserved, unsupported identity, conflicting field values, and page boundaries. These controlled tests do not establish live-model clinical accuracy.

## Checker revision 12: portable structured-report context

Structured ingestion recognizes report shapes rather than jurisdiction, branding or issuer. Supported lab order blocks retain the date, ordering clinician and panel/report-status context for each test, including continued panels across pages. Medication rows retain their active/discontinued/fill headings and column labels; dispensing days supply is not interpreted as dosing frequency. Common heading variants are recognized, unrelated content remains available to general extraction, and unrecognized formats fall back to the existing general path. Adjacent compatible units are batched (at most three) without cutting individual units or mixing medication event types. Known administrative footers are excluded from extraction units while originals remain intact.

Ordering-clinician labels supply unapproved contact candidates even without Dr/MD credentials. Generated body-system/topic classifications and lab current/past defaults are removed from structured-entry citation requirements; actual dates, values, units and attribution still require verification. Report status Final is distinct from patient Current/Non-current controls. Citations must occur both in the supplied evidence unit and the original saved transcript, so reconstructed context cannot create fictitious contiguous quotations. Existing records reprocess under revision 12. Tests cover an anonymized portal-style report, unbranded heading variants, row distinctions, cross-page order context, contact labels, non-admission of unchecked candidates and batching. This is not a claim of coverage of every provincial template; live model extraction quality still requires evaluation.

Verification responses now contain decisions only. Single-assertion correction and small-window omission discovery run separately, followed by the existing independent final check. Failed records remain retryable while other records can finish and commit; cancellation stops the run. The processing message reports saved and unfinished totals rather than implying an all-or-nothing global summary.

## Revision 13 — useful source-linked information without a completeness gate

The patient feedback supersedes the earlier strict publication policy. Missing optional fields,
citation metadata, or a technical checker failure must not hide otherwise source-linked extracted
information. A separate `sourceLinked` admission publishes it with patient review still pending;
it is not a claim of automated verification. Original links, edits, deletion, statuses and history
remain available. PDF source history explicitly identifies an incomplete automated check.

Checking runs in small batches; failed batches fall back to lightweight original-text anchoring.
Clear checker exclusions (wrong patient, contradiction, non-patient material, unreadable evidence)
and recognized boilerplate remain source-only. Extraction itself must still return usable data.
Optional provider enrichment cannot abort publication of the record. Cancellation and stale-write
protection remain enforced. Cross-source automatic semantic combination still requires strictly
supported evidence; adding this admission does not make it eligible for that stronger operation.

This is intentionally more permissive and can admit extraction mistakes. It is not a medical
accuracy guarantee. Revision 13 invalidates prior processing versions so existing records can
benefit on regeneration. Regression coverage includes incomplete labs, medication names without
dose, explicit contradictions, boilerplate, patient deletion and changed sources/content.

## Revision 14 — history presentation and independent duplicate checking

Medication dispensing occurrences now share one presentation when medication name, strength and
form match; the latest clinically dated occurrence is shown first. Every occurrence remains
editable in its original record. Explicit start dates may be displayed as First recorded start;
fill dates never become inferred start/end dates. Different strengths and conflicting saved
patient preferences remain separate. Hidden preferences survive additional fills.

Contacts sharing a name, phone/email and organization share one display. Typed fields supplement
one another; a specific specialty replaces a generic Practitioner label, and fuller addresses
are displayed with sources retained. This is a presentation projection, not deletion of older
contact entries. Repeated serialized contact fields and title-equivalent fields are suppressed
in the story and PDF.

Structured lab units route result entries from Findings to Tests & Labs before checking. General
extraction guidance also reserves Findings for diagnoses and clinical impressions. Regeneration
is required to correct previously published categories.

Symptom semantic comparison now discovers candidates by the first concept word rather than two
literal title words. It can retrieve original record text when optional citation metadata is
missing, independently of admission. Candidate discovery does not establish equivalence: the
original-source comparison still decides. Actual live model outcomes are not asserted by local
regression tests. Persistence suite: 131 passing tests including repeated fills, different
strengths, removed medications, complementary contacts, lab routing and paraphrase discovery.

## Medication product identity normalization

Medication history grouping now uses `MedicationIdentity`, rather than concatenating title and
separately extracted dose text. Strength is parsed once from the title, or from structured
strength/dose fields when absent there. Case, whitespace and decimal formatting are normalized;
pharmacy/fill prose and repeated dose metadata do not split a named product. Distinct strengths,
forms, brand/generic names and unresolved explicit strength conflicts remain separate. This is
local presentation grouping of original occurrences, not a clinical equivalence assertion or
source mutation. No regeneration or cloud request is required for existing entries.

Regression cases exercise multiple medication names plus synthetic products, missing/repeated
dose metadata, strength moved between title and field, concentration ratios, differing forms,
and ambiguous strength. Persistence suite: 134 tests passed.

## Revision 15 — entity structure before display

The existing extraction model is instructed to classify entities before formatting and keep
attributes inside their parent objects. Named but incomplete entities remain admissible. Shared
structural validation rejects generated standalone field labels (strength, frequency, phone,
result, etc.) and medication strength-only fragments, independently of permissive source-link
admission or a model's supported decision. Existing generated fragments are excluded from all
surfaces that use verified projection; original entries remain accessible with a specific reason.
Manual entries and edits are not overridden.

Legacy multiline parsing preserves indented attributes within the preceding item. It does not
attach unbound attributes across blank lines or separate list items, avoiding guessed ownership.
The change retains existing consolidation and patient controls and uses no additional model or
service. Regeneration applies the updated extraction instructions; old fragments are hidden on
load without cloud reprocessing.

## Narrative overview and measured processing (September 21)

After record publication and symptom consolidation, the selected existing model writes one
chronological introduction, followed by one independent support check. Sentences reference accepted
fact IDs; malformed references, unsupported narrative, cancellation, context overflow or concurrent
patient edits prevent publication. Cache storage is atomic and file-protected. Its fingerprint covers
entry revisions and patient status/review choices, so refreshes cannot display a stale narrative.
A deterministic clinical-date-based overview remains available if generation fails. Full-selection
PDF export uses the displayed overview; partial export uses only selected facts in its local overview.
The model is instructed not to turn historical prescription fills or default Current controls into
claims of current medication use. Generation uses the selected processing mode with no cloud fallback.

Optional fact checks now make one attempt per batch and fall back to source-linked admission on
technical failure. Up to three independent cloud batches run concurrently, with stable result order;
on-device checks remain sequential. Extraction and record commits remain sequential. Duplicate
verification safeguards are unchanged. UI progress identifies reading/checking sections, contact
organization, saving, symptom comparisons and story generation.

OSLog subsystem com.CollectiveCare.pilot, category SummaryPerformance records model_request stage and
seconds, extraction seconds (including direct on-device generation), record_total and refresh seconds.
Logs contain no record titles, source text or model responses. Sum request durations by stage and
compare with record_total (parallel request durations overlap) to locate bottlenecks. Device/network
performance has not yet been measured; no percentage speed improvement is claimed.

Validation: 143 persistence tests passed, including three-operation concurrency bounds, output order,
cancellation, overview references, clinical chronology, reload, hidden-preference invalidation and
stale-write rejection. Run a device regeneration to assess narrative quality and actual wall time.

## Revision 16 — complaint-led story and native contact actions

Extraction explicitly identifies the documented primary reason for care, distinguishing it from
other symptoms, tests and encounter labels. When symptom extraction succeeds but no visible chief
complaint exists, one bounded recovery pass examines the original record and requires a source
excerpt. It does not promote journal entries or invent a primary concern. The step appears in
progress as Identifying the reason for care and logs under chief_complaint. Very large sources
remain handled by the ordinary per-chunk extraction instructions rather than silently truncated.

Narrative instructions now lead with the relevant chief complaint (or stated concerns if none is
established), then develop the history chronologically. Older prescriptions must not displace the
reason for care. Existing narrative caches are invalidated by a new narrative fingerprint version.
The local fallback also places concerns before dated history.

Contact controls use separate borderless buttons, tel URLs for phone numbers and maps URLs for
Apple Maps searches. Addresses retain their full query value. Extensions are not appended to the
base telephone number. Automated URL tests do not place calls; physical-device routing still needs
patient-build confirmation. Persistence regression suite: 146 tests.

## Patient-readable overview (September 21)

The generated overview is now explicitly addressed to a patient sharing their story, using plain
language and connected prose. It excludes inventories of measurements, acronyms, prescription
strengths and dispensing dates. Essential terminology can be explained accurately; suspected and
rule-out diagnoses must remain investigations, never established conditions. The support check
accepts faithful plain-language paraphrases and also checks readability.

The raw title/date fallback is no longer displayed as the main overview or included in partial
PDF exports. If a narrative is unavailable, an inline Create overview action retries only narrative
generation using the selected backend and existing consent flow. Category entries remain available.
Narrative cache version changed so previous clinical-style paragraphs do not persist. Repeated
original excerpts are omitted from the narrative input; accepted facts and their dated descriptions
remain, reducing redundant context. Live output quality still requires a device generation check.

## Revision 17 — immunization routing, fragments and overview diagnostics

Standalone immunization reports with administration headers are recognized structurally. Within an
immunization source section, generated medication/test/finding items route to Vaccinations before
checking. General extraction guidance also categorizes vaccine records while preserving the
important distinction between a pharmacy fill and documented administration; no brand-name list
or inferred administration date is introduced.

Attribute-label recognition now normalizes spaces/underscores/case and includes dispensing metadata.
Camel-case field fragments are excluded before visible projection; clinical acronyms such as eGFR
remain allowed. Previously saved fragments remain accessible in originals. Their disappearance
after regeneration is not treated as acceptable draft UI: admission filtering applies on every read.

Overview requests remove repeated identical historical descriptions and dates. Support checking
judges factual support rather than style/completeness. Specific errors distinguish request size,
response formatting, missing references and unsupported claims; the app no longer hides those
behind one generic notice. The exact cause of the reported device failure is not recoverable from
its old screenshot. Validation: 149 persistence tests, including isolated immunization reports,
dispensing attributes and overview diagnostics. Device regeneration remains necessary to verify
real model classifications and narrative completion.

### Overview response contracts
The narrative writer and factual support checker now request separate strict JSON schemas in cloud mode (same model and existing proxy). On-device overview calls use Foundation Models typed generation for the equivalent sentence/reference and boolean structures. This removes reliance on prose instructions alone to produce a decodable object. Complete JSON fences are accepted by the shared decoder; truncated responses, absent references and non-boolean support values are not silently repaired or approved. Writer-format, checker-format and refusal messages are distinct. Existing reference validation, factual checking and atomic publication remain in place.

Validation: 152 persistence tests passed, including malformed/truncated narrative, fenced JSON, negative/missing/string/numeric support decisions and nested schema requirements. iOS simulator build passed. No live patient response was sent to a model during these checks; the specific original failing response was not available.

### Compact overview citations
Overview generation and its support check now use compact request-only codes (`F001`, `F002`, and so on) instead of asking a model to reproduce internal durable identities. The app translates those codes back before it validates references or publishes the overview. An unknown code still fails safely. This is particularly useful for small models while retaining the same source-linking safeguard. Validation: 153 persistence tests and the iOS simulator build passed.

### Overview publication and reload

September 24: overview output is plain narrative JSON with a single text field; the app attaches input-snapshot references itself. Model-generated sentence citations are no longer a publication requirement. Accepted entries exceeding the request budget are partitioned without dropping input, condensed and progressively reduced before the final narrative request. This is presentation summarization only, not source verification. Failed or in-progress transcription records are excluded from both automatic and forced summary preparation; the original transcription error is retained with the saved record for recovery.

Current behavior (September 22): the overview is a single narrative-generation pass over the accepted, visible health-fact projection, including patient-maintained entries. It does not consume original source documents and does not run a separate support checker, rewrite or recheck. Earlier descriptions of those overview steps below are historical. The narrative prompt retains attribution, uncertainty and chronology guidance. JSON decoding, reference integrity, cancellation, content fingerprinting and atomic saves still apply; these are technical publication checks rather than another clinical admission gate. Category extraction and verification are unchanged. Existing checker diagnostic types remain for compatibility but are no longer produced by overview generation.

The overview checker now returns specific correction feedback with its boolean decision. A rejected narrative receives one automatic rewrite against the same accepted input and another independent check. Only a supported corrected narrative can be published; missing checker fields remain a technical failure. Cloud and on-device contracts both include the feedback field. Targeted contract tests and the simulator build pass; live model acceptance still requires device validation.
Create overview now uses a dedicated model operation without triggering record repair or reloading the home list. It reads back the committed result and provides explicit failure/cancellation messages. Refresh guards both sides of the asynchronous overview read so an older refresh cannot overwrite newer state.

A regression reproduced an overview disappearing after reopening the store: in-memory entry revision timestamps retained fractional seconds while session JSON persisted whole seconds. The overview fingerprint now uses occurrence content hashes and patient choices rather than timestamp revisions. Repeated consolidation/reprojection after reopening retains the overview; content edits still invalidate it even when their timestamps match. Existing overview caches require one regeneration for the new fingerprint version.

Consolidation now explicitly uses occurrence-level fact groups, before medication/contact history is grouped for display. Previously it persisted a presentation group's identity onto distinct events; the next refresh split and regrouped them, appending another split suffix and invalidating the overview indefinitely. A regression reproduced this identity growth, then verifies an already affected medication history is repaired, stays one displayed item with two occurrences, and retains a saved overview across repeated refreshes. The persistence suite passes 154 tests.
