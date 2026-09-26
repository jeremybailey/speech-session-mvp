# Condition organization stress test

`Tests/SpeechSessionPersistenceTests/ConditionStressTests.swift` calls the production `ConditionSynthesis.organize` path, including batching, retry, reconciliation, and final coverage validation. It uses generated synthetic records only.

## Local fault injection

Run `swift test --filter ConditionStressTests`.

Four 320-entry histories exercise clean output, repeated/unknown IDs, omissions requiring selective retry, and malformed JSON requiring bounded retries. Every trial must produce four distinct concerns and account for every entry. September 26 local results: all four passed; request counts 14, 14, 26, and 28 respectively. The clean trial processed 741,456 serialized input bytes across requests. These are mocked responses, not model reliability measurements.

## Live repeated trials

Provide a credential through the environment, never commit it or paste it into logs:

- Direct OpenAI: `OPENAI_API_KEY`.
- App proxy: `CONDITION_STRESS_URL` (full HTTPS chat-completions endpoint) and `CONDITION_STRESS_TOKEN` (a valid test-account bearer token).

Run `CONDITION_STRESS_LIVE=1 swift test --filter ConditionStressTests.testLiveRepeatedLargeHistory`.

The test performs three independent 240-entry trials with the production model, prompt, request settings, organizer and recovery logic. This incurs API usage. It checks complete ID coverage, expected grouping, no conflation of distinct/lateralized concerns, and no unassigned entries in this deliberately explicit fixture. Per-trial latency, request counts, group counts, unresolved counts, and safe error types are saved after each trial to `/tmp/condition-stress-live.json`. Override the report location with `CONDITION_STRESS_REPORT`.

Default networking uses the direct OpenAI endpoint; to measure the app proxy's timeout/authentication path, explicitly supply its endpoint and test-account token. This does not exercise the phone's token refresh, screen locking, connectivity changes, or UI. Passing three trials is a smoke test, not a statistically reliable failure-rate estimate. Existing `scripts/evaluate_condition_synthesis.py` complements this with smaller semantic fixtures (uncertain eye concerns, laterality, historical medications, normal findings, and priorities).

No credentials or proxy endpoint were available during the initial local run, so live trials were skipped.

## Signed-in simulator results — September 26

Ran the actual app `RecordSummaryProcessor` and signed-in Kinde proxy on the isolated Condition IA QA iOS simulator. The debug-only `--live-condition-stress` runner generates 240 synthetic accepted entries in memory and saves no synthetic patient records. Three trials completed in 97.46, 92.96, and 94.04 seconds. All passed whole-history link validation, returned three non-mixed condition groups, and explicitly left 60 entries unassigned. None reproduced the tester's invalid-links or size error. The original strict four-group expectation failed all three trials; it has not been retroactively changed in the reports.

A fourth diagnostic trial (94.65 seconds) identified the unassigned items as all 60 “Hormone testing” entries. These merely mention testing, with no result or explicit ongoing concern; leaving them in All is defensible. The three named concerns (migraine, left knee injury, right knee pain) remained separate. This fixture does not establish performance on abnormal hormone panels, pregnancy histories, ambiguous diagnoses, or the tester's real history. Four successful service completions are not a reliable population failure-rate estimate.

Reports: `docs/test-results/condition-live-2026-09-26.json` and `docs/test-results/condition-live-diagnostic-2026-09-26.json`. The signed build was necessary for simulator keychain session persistence. An initial debug runner attempt was cancelled by the view's refresh task before meaningful model testing; the runner was moved to an independent task before these reported trials.
