# Original checklist: current implementation status

Reviewed September 13, 2026 against [the original planning document](https://docs.google.com/document/d/10T59CRL1bAUTmqjV6eKf-Nfcplpu4UMZyjv0lR3DQk4/edit).

**Implemented** means present in the current local code, not verified as distributed through TestFlight. **Partial** means the checklist's behavior is not fully delivered or still needs quality validation. This assessment follows the current single-page direction and preserves the twelve clinician-vetted category names.

## Items the original document called shipped

| Original item | Current status | Notes |
|---|---|---|
| Print-ready PDF sharing | Implemented; hands-on verification pending | Select details, preview a PDF, and optionally attach selected originals. Native share sheet. No provider portal or revocable access. |
| Original files attached / source links | Implemented | Saved PDF, image, audio, and text originals remain accessible. Transcript/extracted text is visible alongside originals. Files absent from older records cannot be recreated. |
| Hide empty summary sections | Superseded by patient feedback | All twelve vetted categories remain visible, including empty ones. Opening an empty category offers Add detail (or Add contact for Care team). |
| Consent before recording/importing audio | Implemented in the Add record sheet | Appointment and journal choices and imported audio have consent steps. Shortcut, lock-screen and shared-file entry paths still need a complete consent-path audit. |
| Repeated facts stack with source history | Implemented with limits | Matching normalized fact keys consolidate occurrences. Details retain source history; the list now shows the source count. This is not guaranteed semantic deduplication of differently named facts. |
| Current / Past on the card face | Restored | Explicit Current/Past buttons appear with summary details in the expanded category, without opening the editor. Unknown status stays unselected until chosen. Care-step completion remains distinct. |
| Care team category and extracted contact blocks | Implemented | Extracted contacts can be reviewed, saved, edited and linked to an existing contact. Adding a contact grants no record access. |
| Collapsible categories, divider and count | Implemented | Native inline disclosure groups on one home screen. |
| Journal capture intent and non-visit prompt | Implemented; journal schema remains partial | The prompt explicitly excludes “waiting for it to go” as a plan. Journal data still uses the common summary schema. |
| Overview paragraph above summary categories | Restored with a simpler implementation | A short paragraph is assembled from saved facts and immediately follows status/removal changes. It is not the former AI-generated longitudinal narrative and adds no model request. |

## Remaining checklist and feedback

| Checklist area | Status | What exists / what remains |
|---|---|---|
| Clinically meaningful dates | Partial | Explicit event dates and partial date text are supported; import-date fallback was removed for generated facts. The list now displays the latest occurrence's recorded event date when supplied. Separate document/encounter dates, reliable extraction across real records, and a clinical timeline remain unfinished. |
| Life context / mental health | Partial | Biopsychosocial Context is visible when populated; prompts and structured output include mental health, caregiving, social context, diet and lifestyle. No first-class dated life narrative; recall of actual patient context is not validated. |
| Prompted intake voice note | Missing | Appointment/journal recording and manual entry exist; the three-question, skippable intake experience is not implemented. |
| Add care team during activation | Partial | Contacts can be added from the same Add record sheet even when the category is empty. No guided/skippable activation step. |
| Request prior records | Implemented; hands-on verification pending | Choose a contact, choose years, preview a prefilled email and open the mail app, or copy the draft. Sending and importing the returned records remain patient actions. |
| Medication doses, reasons started/stopped, supplements | Partial | Evidence fields support dose/frequency/start/stop reasons; prompts include supplements under Medications. Missing medication fields are not yet consistently created and flagged for correction. Real medication extraction and deduplication need evaluation. |
| Findings: who, how, when; link to test | Partial | Practitioner, assessment method, event date, excerpt and source-session links exist. Reliable attribution and explicit finding-to-test relationships remain incomplete. |
| Homecare classification by function | Partial | Prompts distinguish homecare, treatment received, self-directed and uncertain instructions. In-clinic treatment is excluded from actionable steps. No validated evaluation against the supplied examples; exercise/education/lifestyle/referral grouping is not yet presented. |
| Current/completed/previous care plans | Partial | Status, Mark done, Undo done and optional reminders exist. Completed treatments and previous plans do not yet have separate presentation sections. Recommendations from different source entries intentionally remain separate. |
| Care plans grouped by condition | Not delivered in current UI | Explicit many-to-many condition links exist in the data model. The one-page UI uses vetted categories, without condition parents or condition-specific plan filtering. |
| Chief complaint vs symptoms vs tests | Partial | Rules explicitly distinguish these, including routine checkups and non-visit lab results. Quality has not been verified against the reported misclassifications. |
| Body-system labels / organization | Partial | Supplied body-system evidence appears on fact rows. Missing/legacy labels, reliable classification, and body-system organization of the summary remain incomplete. |
| Missing information and patient review | Partial | Inline review indicators, reasons and patient check-off exist. No dedicated consolidated review inbox; missing baseline fields are inconsistently flagged. |
| Hallucinations / ambiguous information | Partial | Unknown status/date handling and literal excerpt checks exist; uncertain actions are excluded from next steps. Literal excerpt matching does not prove that a medical claim is supported. Needs evaluation for false positives and omitted recommendations. |
| Recording → complete transcript → complete care plan | Partial | Originals are saved before processing; file-first transcription and bounded chunks are present; incomplete text is flagged. Hardware recording and end-to-end extraction quality remain unverified. |
| Swipe deletion | Restored in code; gesture verification pending | Summary swipe removal preserves sources and offers Undo. Original-record swipe opens an explicit deletion confirmation. Trash actions are separate from the edit action. |
| “Check with provider” for self-directed additions | Partial | Self-directed care steps can have reminders and provider-discussion text. No automatic detection of new supplement/exercise changes or recommendations from trainers/webinars. |
| Dedicated exercise-plan upload | Missing | Exercise documents can use the generic PDF/photo import. No dedicated type or exercise-specific parsing/review. |
| Diet & lifestyle card | Missing as a separate category | Context is captured under Biopsychosocial Context to preserve the vetted taxonomy. A separate category remains a product/taxonomy decision. |
| Personal Health Number | Partial foundation only | Profile storage and an optional PDF inclusion toggle exist; there is no patient-facing entry/edit field. |
| Follow-up nested under Care Plans | Not delivered | It remains a separate vetted category in the single list. Can be reconsidered without introducing another screen. |
| Concise current summary with brief history | Partial | Shared facts show the latest occurrence and source count; source history is available in the detail sheet. First/last-documented medication history and a concise longitudinal history are not complete. |
| Summary freeze with many entries | Mitigated, not verified fixed | Projection runs off the main actor and a 500-record/10,000-occurrence integrity test passes. No representative-device performance measurement or interactive regression reproduction yet. |
| Fitbod / RP Strength / AI-gym integration | Deferred, not implemented | Explicitly a later-version item in the original document. |
| Invite-to-view / provider permissions | Deferred, not implemented | Selective PDF sharing is implemented; invitations, account access and revocation are not. |

## Next work, in order

1. Verify the restored gestures, status controls, source viewer and PDF sharing on hardware with standard and large text. Compare the same patient tasks with the original design.
2. Evaluate transcription and extraction against representative, consented examples: missed midwife recommendations, unsupported symptoms, journal content, medication dose/reasons, and in-clinic treatment versus homecare. Prompt changes alone do not close these items.
3. Make missing medication/diagnostic fields consistently editable and flagged; resolve date attribution and routing failures demonstrated by that evaluation.
4. Add the optional intake, Personal Health Number entry and remaining lightweight care-plan behavior only as simple inline content or focused task sheets. Preserve the approved one-page structure.

No completion percentage is used: a critical extraction-quality failure is not equivalent to a missing display preference. Nothing in this status file asserts a new release or clinical validation.

## Health story revision — September 13, 2026

This revision supersedes the earlier flat-category and inline status-control descriptions:
- Home is now **My health story**, still one native list, with condition/body-area parents and General health for unattributed details. Each parent shows an overview even when closed; opening it reveals the unchanged vetted category headings without additional category menus.
- Source-supported relationships permit the same fact under multiple concerns. Patient edits update its shared identity; the detail editor can change associations (one name per line). Removing a detail hides it from every group; Undo restores it and original records remain intact.
- Current/Past, editing/review, completion and removal are consolidated in an Actions menu.
- Care plans distinguish care steps, treatments received, completed/past/paused steps, and recommendations to clarify with the care team. Legacy schema labels are suppressed in story/PDF presentation; extraction accepts instruction-only care objects and carePlan/carePlans aliases. Version 5 offers reprocessing for older extraction.
- Grouping is deliberately source-based: unlinked legacy facts remain General or their explicit body area until corrected/reprocessed. A body-area match alone does not establish a condition relationship.
- Validation: 42 persistence tests pass including shared group identity, General override, body-area fallback and legacy care-text cleanup. iOS simulator build checked. Interactive menu/edit/share and patient comprehension still need hands-on testing.

## Single-list restoration — September 13, 2026

Patient feedback supersedes the condition-group UI above. Home again presents one color-coded list of the vetted categories, expanding inline, with each fact appearing once. Removed condition-parent overviews and relationship-editing controls from the interface; existing relationship metadata is preserved. My health story, the whole-story overview, Actions menus, clearer care-plan presentation, original records and sharing remain.

## Care instruction list — September 13, 2026

Care Plans now uses one complete instruction plus non-redundant directions, goal, schedule and review timing when recorded. Cloud and on-device extraction support these optional fields (extraction version 6). Missing metadata produces a specific review indicator, not generic provider-check advice. Recurring/unknown-frequency instructions use current/no-longer-current controls; explicitly one-time instructions can be completed. The editor can correct the instruction and its optional fields.

Equivalent recommendations from the same source with matching evidence/clinical metadata are linked under a persisted identity without deleting source entries. Saved patient preferences protect against automatic consolidation. Actions offers a manual duplicate preview and Undo; conflicting preferences (and duplicate reminders) prevent combination. Reprocessing retains linked source history and patient changes. Overview and selected PDF export consume the same consolidated facts and instruction presentation. No new condition grouping.

Validation for this revision: iOS 27 simulator build succeeded; 52 persistence tests passed. Synthetic standard-size list, editor and PDF renders were inspected; the accessibility editor label truncation found during QA was fixed and rechecked. Source excerpts in PDFs are explicitly labelled and identical excerpts from the same source are shown once. Actual menu gestures, VoiceOver and patient comprehension remain hands-on acceptance checks; no live patient data was used for these renders.

## Information design — September 13, 2026

All health categories share a consistent hierarchy: bold primary information, compact status tags, bold field labels, then secondary source/date information. The review tag is **Unverified** (not yet checked by the patient), distinct from Current/Past/Completed. Actions use a consistently positioned top-right ellipsis with an accessible name and 44-point target. Saved providers and original records follow the same action placement. Provider phone, email and address appear on separate labelled lines with call/mail/map links; optional multiline address storage preserves compatibility with older contacts. Category taxonomy and the single-list navigation are unchanged.

Design reference: Nielsen Norman Group's visual hierarchy, proximity and consistency guidance (https://www.nngroup.com/articles/principles-visual-design/). Icon-only actions follow the user's explicit preference; NN/g generally recommends visible icon labels, so accessible names and patient recognition testing remain important.

## Persistent status and deduplicated details — September 14, 2026

Current is the display default when a source does not explicitly establish historical status. Unverified remains independent: default Current never implies that the patient checked the information. The More menu shows only the opposite current/non-current action; one-time current care steps may additionally be completed. Status pickers have been removed from the edit sheet to consolidate controls. Completed and Verified tags are green, Unverified/Paused orange, Current blue and Non-current neutral, with text retained so meaning does not depend on color.

Structured category fields take precedence over repeated prose, including multiline provider addresses. Non-redundant notes and clinical directions remain visible. Patient decisions acquire a persisted fact identity; regeneration retains it through matching/renaming and keeps unmatched patient-controlled facts instead of discarding their status. Exact-source fallback matching is used only when unambiguous. Original source text remains unchanged. Duplicate-combination undo continues to restore separate facts.

Validation: 57 persistence tests passed, including Current default vs verification, historical status, address deduplication, non-redundant clinical prose, regeneration/omission/reload, and existing duplicate undo tests.

### Compact status metadata — September 14, 2026

Status pills now sit at the bottom of each entry after fields, sources and reminders. They use Dynamic Type caption2 medium text with 6-point horizontal and 2-point vertical padding. All health, saved-contact and original-record rows share 8-point vertical padding and 6-point content spacing; bottom tags use a consistent 4-point separation. Top-right action targets remain 44 points. Semantic colors and status behavior are unchanged.
