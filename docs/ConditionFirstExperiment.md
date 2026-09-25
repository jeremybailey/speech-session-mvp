# Condition-first summary experiment

Branch: `codex/condition-first-summary`. The reconstructed category-based iteration is preserved at `b9bd004` on `codex/category-summary-checkpoint`; the condition-first changes follow as a separate commit.

## User experience

Conditions is the default summary organization. An expandable All bucket retains every existing global category and care-team entry, including details with no condition assignment. There is no segmented organization control or visible Uncategorized bucket. There is no body-system navigation, folder model, or mandatory three-level drill-down. The overview is displayed in full. Conditions have body-system icons, with a neutral person icon for unknown systems.

Each condition expands in place into relevant category headings. Recommendations and follow-up appear first, followed by symptoms/reasons for care and other existing categories. Repeated identical/aliased symptom and chief-complaint titles have one concern heading; individual source details remain expandable. Conditions and details sort by newest known clinical date, unknown dates last. No import date is substituted for a clinical date.

Current/not current and unknown status are edited in Health detail, alongside completed/paused states for care actions. The summary has no status filter or status-changing controls. Existing read-only status labels remain visible. Category headings within each condition use the familiar icon, count, and disclosure control.

Recommendations display recorded practitioner/date metadata, explicit missing-data labels, and links to original records. Source records remain accessible through each detail; redundant condition-level source lists are omitted. Original files and summary occurrences remain independently stored and editable. Linked provider contact cards appear only when explicitly linked; a doctor mentioned in a record is not automatically attributed as its recommender.

## Data model

No destructive migration or second clinical truth store is introduced.

- `SummaryEntry`: original category, title, fields, provenance, clinical date/status and source session identity.
- `ClinicalEvidence.topicNames`: source-derived condition candidates; `bodySystem`: internal disambiguation metadata.
- `HealthTopic`: an existing persisted named condition/concern plus optional internal body system.
- `HealthFactPreference.topicIDs`: explicit patient assignment. `nil` permits source-derived classification; `[]` explicitly means Uncategorized. This is not a user-created folder.
- `ConditionSummary`: disposable projection with canonical key, display name, internal body system and occurrence-preserving facts.
- `ConditionSummaryProjection`: normalization, association, status and ordering rules shared by UI/tests.

Assignment is per occurrence, not per product. One medication history with different indications can appear under multiple conditions with only the applicable source occurrences in each. A manual condition assignment applies to the selected underlying fact (which may itself be a combined history), and the detail editor still opens that underlying fact.

## Classification rules

1. Explicit patient condition assignments win, including an explicit Uncategorized choice.
2. Otherwise use extracted topic names only when they match the concern's title or explicit linking words in that occurrence's source excerpt (`for`, `because of`, `related to`, `due to`, `indication`). A shared document, specialty, or body system alone never establishes a relationship.
3. Chief-complaint and symptom titles can seed a concern without asserting a diagnosis. Findings, labs, medicines and plans without a supported topic are left Uncategorized.
4. Normalize case, punctuation, whitespace, diacritics and a deliberately small alias list (migraines/migraine, headaches/headache, knapsack/backpack). Preserve laterality, chronic/acute qualifiers and distinct symptom/diagnosis names. Headache is not assumed to be migraine.
5. Same canonical condition name plus compatible body system groups together. An unspecified system may join one unambiguous known system. If that name exists in multiple systems, unspecified occurrences remain Uncategorized.
6. Keep every source entry ID. No clinical event is deleted, overwritten or deduplicated by this projection. Existing medication/history grouping and patient preferences remain upstream.

The existing extraction model receives explicit instructions to populate condition topic names only for supported relationships and to preserve uncertainty. This fork adds no extra model call. Deterministic linking deliberately favors reviewable omissions over speculative connections.

## Assumptions and failure modes

- This is a conservative prototype, not full medical entity resolution. Paraphrases, acronyms and broad/narrow diagnoses may remain separate. The patient can assign them to a shared condition; stronger semantic alias proposals need evaluation before automatic linking.
- English linking phrases miss some valid relationships, especially other languages or terse tables. These remain Uncategorized. Even relationship wording can occur in a negated or hypothetical sentence: original qualifiers remain on the detail, and extraction quality still matters.
- Source excerpts may be absent in older summaries. Existing symptom headings still work; other details may need manual assignment or regeneration. A lab panel without a documented indication is not automatically assigned a diagnosis or pregnancy context.
- Body-system wording has not been standardized comprehensively. Conflicting labels can produce separate similarly named groups; vague concerns need patient clarification rather than guessing.
- A generated topic is not independently proven solely by string matching. Keep original text review accessible. Do not interpret a condition heading as a confirmed diagnosis.
- Conflicting historical/current occurrences yield Unknown unless the patient chooses a status. The All view retains its existing status presentation; this experiment's stricter Unknown treatment is in Conditions.
- Condition assignments for grouped facts apply to that whole fact. Per-occurrence manual overrides are follow-up work. Source IDs and original occurrences are retained to support that change.
- PDF sharing remains the existing selected-category export, not a condition-organized export. Selecting Conditions does not implicitly limit a shared PDF.

## Short longitudinal test plan

Use synthetic records from several years and at least two providers:

1. Add `Migraine`, `MIGRAINE`, and `Migraines` in symptoms/chief complaints and an explicitly linked diagnosis. Expect one condition, one repeated-concern heading, all original mentions accessible. `Headache`, left/right concerns, and qualified migraine subtypes must not silently collapse.
2. Add historical medication fills, one documented discontinued medication, one explicitly current medicine, and one unknown-status fill. Expect correct Current/Not current/Unknown labels; a fill date alone does not prove current use. Verify status changes in Edit survive refresh/relaunch.
3. Add 40 hormone results with an explicit hormone-testing indication, fetal-position findings tied to pregnancy care, and unrelated knee findings. Expect separate condition groups. An unlinked result remains Uncategorized.
4. Add old and current care plans from two named practitioners. Expect plans first, newest known clinical dates first, practitioner and original-record links visible. Missing attribution/date must say so, not use another provider or import date.
5. Assign an Uncategorized detail to a condition; then clear its assignments. Verify links persist, sources remain untouched, and it returns to Uncategorized. Test multiple links and a medication history with two explicit indications.
6. Expand All: all existing categories, contacts, edit/merge actions, and original records remain available. PDF selection continues to use the full selected fact set.
7. Try largest Dynamic Type, VoiceOver, long condition labels and a 100+ detail history on a phone. Confirm there is no body-system navigation step and original records remain reachable.

Automated coverage: repeated concerns, preservation of source IDs, large distinct panels, historical/unknown status, no inference from body-system/document co-occurrence, patient overrides, medication occurrence isolation, provider/date ordering and ambiguous body systems.

## Follow-up work after this fork

- Provider attribution: distinguish author, ordering clinician, prescriber, recommender and referenced provider; retain attribution per occurrence instead of relying on the latest card alone.
- Date ordering: support partial/ambiguous dates and date ranges without inventing precision; distinguish encounter, result, prescription and dispensing dates.
- Current/historical: reconcile contradictory longitudinal statements, represent medication courses and discontinued/restarted care, and show a three-state status control rather than an off switch plus Unknown explanation. Do not infer schedules here.
- Condition classification: evaluate semantic alias proposals and panel/context extraction across jurisdictions, normalize body-system vocabulary, and explain why an association was proposed. Keep user overrides and provenance.
- Improve per-occurrence assignment, condition-specific edits/status changes and condition-organized sharing after validating this IA.

## Equivalent concern phrasing

Conditions now share a compact list section. The classifier is instructed to reuse concise names for explicitly equivalent concerns. Projection also normalizes symptom/location phrasing across body sites (for example pain in the right knee → right knee pain), low/lower back, backache/back pain, and pins and needles/tingling. Original entries remain unchanged. Laterality, anatomical level, distinct diagnoses, and separate symptoms are preserved. This does not yet resolve arbitrary semantic relationships across records; those require explicit links or patient assignment. Twelve condition regression tests pass, including source preservation and negative merge cases.

## Contextual condition associations

The existing category classification request now also returns optional `conditionGroup` and `conditionGroupReason` metadata. It receives the source, draft concern descriptions, and condition names already extracted in that draft. This allows different descriptions of one documented concern to share a heading without rewriting or merging the underlying clinical facts. A nonempty explanation is required structurally; it is not independent verification of the model's judgment. Patient assignments take precedence. Missing or uncertain associations retain the previous conservative grouping behavior. No additional model request is introduced.

Existing records require summary reprocessing to acquire these associations. Model decisions may vary across batches or records; this first iteration does not guarantee global semantic reconciliation. Tests exercise the response/application contract using synthetic linked backpack pain/tingling descriptions, not a live model evaluation of the patient's records. Wrong associations can be overridden using Assign condition.
