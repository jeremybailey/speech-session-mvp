# Whole-history contract alignment — November 4, 2026

New generation requests use `category-contract-v9`. Pending requests retain their original payloads. This change adds no model pass or paid retry.

The server now applies the iPhone's instruction-category, instruction-owner and original-overview citation checks before starting the writer. Generation limits fact strings to the app's accepted length and constrains context references to the enclosing original record. Shared named schema definitions avoid repeating category field definitions for every record. Historical medication instructions preserve their historical status.

Concern IDs must be unique, declared and used by a fact. These cross-field invariants remain explicit runtime checks on both platforms: they cannot all be expressed in the provider's JSON Schema subset. The prompt explicitly audits them. Conflicting or unsupported references still stop publication rather than being guessed, discarded or silently repaired.

`tests/fixtures/whole-history-contract.json` in the backend contains 37 synthetic cases consumed by the server tests and the actual production Swift decoder. It covers all categories, historical medication instructions, category projection, length boundaries, source scope, invalid citations, duplicate/unused concern IDs and malformed metadata. Swift also tests changed source hashes.

Validation: 175 backend tests passed; 5 database-dependent tests skipped in this run. Persistence suite: 479 tests executed, 3 skipped, no failures; the shared contract test passed again after final boundary changes. iOS build 45 compiled and installed. A live 20-record synthetic provider request passed server validation in 19.675 seconds (52,307 input tokens, 2,153 output tokens, including 307 reasoning tokens; $0.0063072 estimated API cost). This synthetic timing is not a patient-data or phone performance benchmark. The temporary diagnostic deployments were removed. Production readiness passed without inference.

A full new patient-data update remains to be verified on device. Older failed attempts are not made valid merely by redeploying; new generation uses v9, while retained valid results can be decoded using the aligned client checks.

## Build 46: publication recovery and empty-view failure

The on-device v9 generation completed, but its 106-word, 744-character overview was rejected solely by the 100-word style gate. Subsequent partial publication hit missing lab-category coverage on three records. The startup refresh attempted that publication before loading its saved snapshot; the exception skipped the snapshot assignment and displayed an empty history despite 20 originals and 321 saved details being present.

Recovery publication now consistently retains incomplete source projections, and reconciliation errors are isolated from saved-data loading. The writer still aims for <=100 words. Compact display keeps its 850-character ceiling and accepts up to 150 words, preserving all citation, number and condition-coverage checks. A retained word-limit rejection is promoted only after the entire narrative validates again. No automatic paid rewrite is added.

Fourteen targeted tests passed, including small style overruns, display ceilings and a partial result missing lab categories on three records. Build 46 compiled, installed and launched. Post-launch state confirmed completed generation and narrative, three retained records and a published source fingerprint. All 20 original texts matched their pre-install copies. Temporary diagnostic copies were deleted. No new patient-data inference was requested.
