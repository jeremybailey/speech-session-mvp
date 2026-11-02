# Citation reference recovery

The current processing pipeline is retained. This checkout combines the preserved
care-plan work and recovery fixes with a focused change to compact citation decoding.
The original checkouts and frozen benchmark remain unchanged.

Previously, a response that referenced an undefined evidence ID aborted the entire
checking batch. Even source-backed peer details could prevent the record from
finishing, which stopped conditions, care-plan cards and overview processing.

The decoder now treats an undefined reference or an unmatched quotation as missing
evidence for its entire field. A valid locator in the same field cannot mask the
unusable one. Other fields and sibling decisions survive. Existing assessment rules
keep the affected claim hidden and select it for the existing bounded citation-repair
pass. A claim that remains unsupported stays hidden; no evidence is guessed, no
whole-source fallback is inferred, and no new paid retry loop is introduced.

Malformed envelopes, conflicting evidence IDs, unexpected fields and mismatched
decision IDs still fail validation. Model policy, prompts, output schemas, budget
limits and completed-work identities are unchanged. Interrupted work can resume its
saved extraction and valid checks without reprocessing completed records.

Validation:

- Five synthetic regressions cover unknown IDs, mixed valid/invalid references,
  non-source quotations, successful repair, unresolved claims staying hidden,
  completed-work reuse, and restart after an interrupted repair.
- Combined persistence suite: 420 tests, three skipped, zero failures.
- All five saved diagnostic replies decode offline, including the two previously
  rejected. Missing-evidence claims remain hidden in the field assessment audit.
- Combined iOS Simulator Debug build succeeds with code signing disabled.

The saved-response replay is a decoder and field-admission check, not a new full
patient-processing run or an accuracy benchmark. No provider calls or production
changes were made for this fix. The previous uncertain generation and its reservation
remain unresolved and must not be silently retried or erased.

This is a client-side Swift change and requires a new app build from this combined
checkout's `SpeechSessionApp.xcodeproj`, using the `SpeechSessionApp` scheme. Another
aggregation comparison requires a new frozen baseline and an explicit diagnostic
runtime policy; the earlier comparison did not establish a speed or cost winner.
