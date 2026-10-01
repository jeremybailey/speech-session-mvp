# Patient-friendly health areas

HealthAreaProjection groups existing ConditionSummary values for navigation only. No model request, saved data, condition identity, clinical association, overview input or PDF output changes. Each condition appears in one area; facts can retain their existing links to multiple conditions. Area counts count concerns, not unique facts.

Existing body-system values map to familiar area titles. Only an explicit whole word `pregnancy` or `pregnant` in the existing condition name overrides that mapping. Unknown systems use Other health concerns. This is intentionally conservative: fatigue does not become pregnancy-related merely because pregnancy exists elsewhere in the history. No new clinical relationships or diagnoses are inferred.

Area order follows the first condition in the existing priority order; conditions keep their relative order. Empty conditions and the unassigned projection are omitted, while All remains available. Previews contain unchanged condition names. At standard text sizes previews use two lines; accessibility sizes allow wrapping.

Opening an area shows condition headings directly above expandable categories, with recommendations first as before. A single-condition area uses the same page with its categories immediately available. The destination observes the live model and reprojects from the area ID; it never holds an old copied set of facts. If all conditions move out of an open area, it shows an empty message and retains native back navigation.

## Validation

Automated tests cover all system mappings, unknown systems, explicit pregnancy routing, unchanged identities and source references, priority order, distinct left/right/unspecified hip concerns, single-condition areas, empty/unassigned filtering, and reprojection after reassignment/removal. The large synthetic fixture includes pregnancy, hormone panels, headache, fatigue, mental health and musculoskeletal concerns.

Device usability checks:
- On a small phone and at accessibility text sizes, check title/preview wrapping and native back navigation.
- Open Pain & movement, find each distinct hip concern, expand a category, open a detail and its source, then return.
- Open a single-condition area: categories should be immediately accessible without another condition disclosure.
- Edit/reassign a condition while its area is open; confirm updated content and the empty-area state if appropriate.
- With VoiceOver, check area labels/counts, condition headings, category disclosure and back navigation.
- Ask a tester to find a concern, locate recommendations and trace a source; compare scanning effort with the flat list. Fewer cards alone is not the success criterion.

## Follow-up

Do not treat navigation grouping as clinical deduplication. Group summaries, custom priorities and improvements to inferred condition granularity need separate evaluation. No generated area prose is included in this prototype.
