# Single-view patient pilot

The app opens on **My health story**, a single native SwiftUI list. All twelve existing clinician-vetted categories retain their names, order, and color mapping. Empty categories remain visible and offer Add detail when opened. Categories expand in place. Conditions remain data associations; they are not another navigation layer. A shared fact still has one identity and retains its source history.

A short source-derived overview appears above the categories and follows edits immediately. Current/Past controls are available on the list face. Summary swipe removal preserves original records and offers Undo; original-record swipe deletion asks for confirmation.

Care Plans and Follow-up contain their actions. Eligible current steps have a visible **Mark done** button and **Undo done** after completion. Uncertain instructions do not become current merely because a patient reviewed them. Care team contacts and Original records are in the same home list. Recording/importing, editing a detail, viewing an original, and selecting a PDF to share use focused sheets. There are no home tabs, condition drill-down screens, separate care-plan dashboard, or folder-navigation menu.

The interface uses system lists, disclosure groups, forms, buttons, sheets, fonts, colors and SF Symbols. The iOS deployment target remains 17.0; the installed iOS 27 SDK supplies the current system appearance. At accessibility text sizes, category names sit above their icon and count so these accessories do not squeeze the label.

## What to test with patients

Use the synthetic record in `Tests/Fixtures/SingleViewSmoke/sessions.json` only in a fresh simulator or dedicated test installation. Do not replace a patient's existing sessions file. The fixture includes no real patient information and is not clinical advice.

Give each task without explaining where to tap:

1. Find the main health concern and return to the full list.
2. Find the headache diary step, mark it done, and undo that change.
3. Correct a health detail and find the original words supporting it.
4. Add an appointment recording or a document.
5. Find a care contact, then choose one health detail to preview for sharing.

Observe first tap, completion without coaching, wrong destinations, and whether the patient understands that **Share** creates a copy. Repeat the same tasks with the original design before calling this an improvement. If patients cannot find a category or recover their place, simplify further or revert the presentation.

## Verification in this iteration

- Xcode simulator builds with deployment target iOS 17 and the iOS 27 SDK.
- 38 persistence tests passed, including overview/status updates, empty-category hiding and removal/restoration: original preservation, migration, concurrent edits, explicit status, shared facts, action completion, source validation, chunk coverage, and retaining 10,000 occurrences across 500 records.
- Home-screen rendering inspected on an isolated iPhone 17 / iOS 27 simulator with synthetic records, at standard and maximum accessibility text sizes.
- The large-record test checks deterministic data retention, not a wall-clock budget dependent on concurrent builds and simulator load. Device performance remains a separate pilot measurement.
- Device Hub accessibility timed out, so interactive UI completion, VoiceOver traversal, PDF share completion, and recording on hardware have **not** been verified in this pass. These need hands-on testing before patient distribution.
- Live AI extraction quality and the broader website/document roadmap have not been clinically validated. Invitations and permission-controlled provider accounts remain future work.

Changes are local and uncommitted. Nothing was uploaded to TestFlight or deployed.

The full checklist is tracked in [OriginalChecklistStatus.md](OriginalChecklistStatus.md), separating local implementation from release and quality verification.

### Restored single-list patient test
- Read the whole-story overview and find a detail using the original color-coded categories.
- Open a category inline and use Actions to check a detail, mark it past, or complete a care step.
- Confirm care steps, treatments received and recommendations needing clarification are understandable.
- Remove a detail, undo removal, and confirm its original record remains accessible.

### Care instructions QA

Synthetic fixture: `Tests/Fixtures/SingleViewSmoke/care-instructions.json` includes the backpack/knapsack duplicate and a recurring diary instruction. Only use it in the dedicated QA simulator, never a patient container.

Debug launch arguments `--care-qa`, with optional `--care-qa-editor`, `--care-qa-combine` or `--care-qa-pdf`, open the care section or focused task for reproducible rendering. The PDF argument writes a synthetic test export to the QA app's Documents/care-qa.pdf. These paths are excluded from release builds and never send a share action.

Patient acceptance: understand a single instruction, distinguish extra directions from repeated wording, identify practitioner/date, use Actions, distinguish checking from completion, and combine/undo a duplicate while understanding that originals remain. Hands-on menu gestures, VoiceOver and patient comprehension still need patient/device testing.
