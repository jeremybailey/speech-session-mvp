# V1 practitioner summary feedback audit

V1 build 244 continues the founder-feedback trial from build 243, source `cbcd72b`. The LLM instructions and Steph's feedback tabs were reread on 28 November 2026, including Asha's red responses. V2 is unchanged.

The generation policy, structured metadata, privacy toggle and report tables already existed in V1. This audit repairs presentation and export gaps without changing the processing model, prompts, service configuration or patient records.

## Changes in build 244

- Adjacent points merge only when their condition group, treatment status and period metadata agree. Distinct states and concerns retain their own source links; fragments of one statement remain compact.
- Older saved summaries without the founder policy marker retain their existing presentation until explicit regeneration. Source links remain available for their structured points.
- Default practitioner PDF rendering excludes sensitive details. Explicit inclusion remains available through the existing preview toggle.
- Safety phrase matching now covers possessives and directional wording, including harm toward others and harm to someone's child.
- The PDF date test compares complete labels across line breaks, rather than treating a wrapped year as a missing date.

## Feedback coverage

| Feedback | V1 treatment | Acceptance still needed |
| --- | --- | --- |
| G1, S1.1, S5.5 | Export-only privacy filtering, default on; original summary and records preserved. | Review both toggle positions for missed wording and overly broad exclusions. The filter is phrase based. |
| G2, G3, S5.2 and Steph 5 | Founder policy distinguishes preparation, event and documentation dates; relative periods remain relative; undated history sorts first. | Check real examples of historical events, expired due dates and past appointments against their sources. |
| G4, S1.2, S5.3, S6.1 | Source-backed condition groups are reused across sections; distinct groups cannot merge during presentation. Groups suit each patient. | Confirm the generated grouping and reported functional impact; do not add missing facts from the example. |
| G5, S2.2 through S2.7 | Source-backed practitioner identities, conservative alias rules, actual-care-only instructions, team grouping and contact tables; licence and biographical cleanup. | Confirm aliases, actual care relationships, team membership and name-description alignment in the real output. Similar names alone do not establish identity. |
| S2.1 | The supplied patient identity is excluded from care coordination. | A separately identified ordering or generating clinician is not supplied by the current request. Do not assume that clinician is the patient or invent an exclusion identity. |
| S3.1, S4.1, S4.2 | Founder-marked summaries omit appointment preparation and combine the internal historical coverage ledger with condition histories. | Older unmarked summaries require explicit regeneration to use this format. Confirm prior treatment trials survive. |
| S5.1, S5.4 | Numbered condition groups and chronological When / Detail tables, using concise source-backed wording. | Review shorthand, chronology and retention of uncertainty. |
| S6.2 through S6.4 and Steph 4 | Item / Detail / Status / Date tables; documented treatment response stays in the text; pregnancy care subgroups are requested when supported. | Confirm status, response, discontinuation reasons and dates. Unknown metadata remains unasserted. |
| Steph 3, 6 and 8 | Repeated facts consolidate with citations; app rows retain source links; compact native tables retain repeated headers and the snapshot rail. | Review a regenerated real report and open its source links. Three pages is a layout aim, not a content cap. |

## Deferred decisions

Asha's objections remain in force: no newly inferred clinical mechanisms or advice, no practitioner-specific relevance ranking without a defined recipient, and no practitioner editing or correction-propagation feature.

The open choices about an appointment intake, a separate longitudinal timeline, placement of unsuccessful trials, and grouping cold/cough symptoms remain undecided. Test-record corrections are review cases, never hard-coded patient facts. The source of the reported practitioner-description mismatch still requires comparison with the real records; the synthetic renderer test only verifies row alignment.

## Verification

- Regression tests first reproduced lost statuses, merged condition groups, missed safety phrases and the unsafe PDF API default.
- Complete native persistence suite: **620 tests, six skipped, zero failures**, using the actual V1 sources in a temporary local package with cached ZipArchive. Unrelated remote dependency status scans were avoided; repository fixture and font paths were supplied unchanged.
- Service TypeScript checking passed. All **12** focused founder-policy and temporal tests passed, with no provider calls.
- Native tests cover legacy preservation, source-link retention, compact statement fragments, provider deduplication, privacy preference persistence, full versus filtered exports, treatment outcomes and dates.
- The representative synthetic report retains eight provider rows and 24 historical episodes across three pages. All pages, plus the short report and wrapped date labels, were visually inspected. This is rendering evidence, not a clinical accuracy assessment.
- Whitespace/diff check passed. No patient data or generated real summaries are added to Git.

## Local trial

Open V1 and inspect the existing summary and PDF preview. Tagged founder summaries receive the presentation fixes without another model call. An older unmarked summary keeps its existing format until you explicitly regenerate it.

For content acceptance, explicitly regenerate from the intended records, check the rows above against their original sources, open source links, compare privacy toggle positions, and share the reviewed PDF locally. Keep V2 unchanged while collecting founder feedback. Build and installation evidence are recorded separately from automated content and rendering checks.
