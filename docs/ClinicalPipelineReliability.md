# Clinical pipeline reliability

This change keeps the condition-first interface and moves clinical inference behind a typed, application-owned pipeline. The rollback point is tag `pre-clinical-pipeline-optimization`; work after that checkpoint lives on `codex/clinical-pipeline-reliability`.

## Trust and provenance

The saved source record remains the durable source of truth. Patient additions and edits are patient-confirmed statements. Generated entries enter the portrait only after source and content hashes, required-field citations, and the independent support check all pass. Source-linked or uncertain output remains reviewable in its original record but cannot create a condition or enter the overview.

Category routing and whole-history condition association are separate stages. Condition synthesis must account for every accepted fact ID exactly once. An independent verification pass can only remove a proposed condition name or fact relationship; it cannot add, rename, merge, or move facts. Rejected relationships remain in All. Patient-reported statements retain attribution and do not become confirmed diagnoses.

Overview generation receives only portrait-eligible facts and organized condition context. It returns sentences with supporting fact IDs. Publication rejects unknown IDs and any number, date, dose, or percentage not present in the referenced facts.

## Request boundaries and recovery

- Per condition request: 60 entries, 60 KB, and a conservative 18,000 estimated-token ceiling. The existing 400 KB single-request hard guard remains. Requests are never enlarged or silently truncated.
- At most two model requests run concurrently per app process and per authenticated subject on a server instance.
- One persisted cooldown is shared by a summary job. `Retry-After` and request/token reset headers are honored with jitter.
- A request gets at most two retries; a job gets at most six. Connection loss, timeout, DNS, and 429 responses are retryable. Cancellation, authorization, quota, schema, and clinical-validation failures are not.
- Checked source chunks are checkpointed with source hash, verification version, prompt version, run ID, and completed chunk count. Relaunch resumes those chunks instead of repeating accepted work. The full condition result is written atomically only after proposal verification and whole-history validation; no partial organization is displayed.
- Interactive processing requests iOS's finite background execution allowance. The active stage is persisted as `summary`, `conditions`, or `overview`. If the allowance expires or the process is terminated, the app resumes that stage when it next becomes active; existing record and condition checkpoints prevent completed stages and batches from restarting. Choosing **Stop preparing summary** clears this resume intent.
- Condition organization and overview writing are separate user-visible jobs. Conditions are persisted and shown as soon as organization finishes. Overview generation starts only from **Create overview**, so a slow or failed narrative cannot hold back completed conditions.
- Concurrent patient edits or source changes invalidate stale work before publication.

## Server transport and privacy

`api/v1/health-processing/stages` is a typed endpoint built with the official OpenAI TypeScript SDK and Responses API. The server chooses a model from an allowlist, applies the stage schema, disables SDK retries, sends `store:false`, forwards request and rate-limit headers, and logs only stage, model, latency, status, token counts, cached tokens, finish status, request ID, and remaining rate-limit headroom. It never logs prompts, responses, source text, or extracted facts.

Production defaults remain unchanged until evaluation gates pass: `gpt-4o-mini` for routine stages and `gpt-6-astra` for condition proposal and verification. Server flags `CLINICAL_ROUTINE_MODEL`, `CLINICAL_CONDITION_MODEL`, and `CLINICAL_OVERVIEW_MODEL` accept only `gpt-4o-mini`, `gpt-6-luna`, `gpt-6-sol`, or `gpt-6-astra`. Candidate rollout is Luna for routine extraction/classification, Sol for condition organization and overview, and Astra only for ambiguous escalation. Change one flag at a time and revert the flag immediately if a quality gate regresses.

The OpenAI project must separately be approved and configured for the applicable Healthcare Addendum and Zero Data Retention or Modified Abuse Monitoring. `store:false` prevents Responses application-state retention but does not by itself activate those account controls. Do not use a server-side autonomous agent, remote MCP tools, web search, assistants/threads, or Batch API for live health processing. The app may continue its same synchronous request during iOS's bounded background allowance; it does not create a detached server job. Batch is reserved for synthetic or properly de-identified offline evaluation.

## Quality gates and evaluation

`Tests/Fixtures/ConditionSynthesis/evaluation.json` is a synthetic, de-identified seed corpus covering named and unnamed eye concerns, repeated aliases, migraine, large-panel context, normal findings, historical medication, laterality, provider-specific recommendations, patient priority, ruled-out diagnoses, and non-clinical context. It must receive clinician review before being called a release corpus. Add pregnancy-related care, negation, multiple providers, current and historical recommendations, malformed/adversarial text, and jurisdiction-specific records during that review.

Run `python3 scripts/evaluate_condition_synthesis.py` for offline fixture validation. Run its explicit `--run` mode only with a de-identified corpus and approved project. Compare Luna, Sol, Astra, and the current baseline. Record unsupported displayed facts, omissions, condition precision/recall, attribution accuracy, current/historical accuracy, calls, input/output/cached tokens, estimated cost, and p95 latency. Release requires zero unsupported displayed facts; cost or recall never overrides that gate.

Required failure tests cover simultaneous 429s, quota exhaustion, expired sign-in, connection loss, cancellation, relaunch, malformed structured output, oversized entries, and concurrent edits. Live device validation still needs sign-in expiry, interruption/relaunch, and controlled network-loss checks against the deployed endpoint.

## Rollout

1. Deploy the typed endpoint with current models and shadow only on synthetic/de-identified fixtures.
2. Enable and evaluate one stage/model flag at a time.
3. Compare accepted fact IDs and condition edges before comparing prose.
4. Roll back a flag on any unsupported fact, attribution loss, status error, request-size regression, or sustained p95 regression.
5. Remove legacy transport and unreachable summary code only after behavioral equivalence is established. Until then, direct/BYOK mode retains the legacy compatibility path.

### Source-linked concern eligibility (September 27 correction)

Manual review and automated source checking are separate. At the user's request,
source-linked entries with current source/content hashes may inform descriptive
condition organization and the overview without manual confirmation. This restores
the pre-refactor inclusion behavior; it does not change their review status.
Source-only, contradicted, deleted, superseded, and stale entries remain excluded.

Organization and overview inputs include checking status and source excerpts.
Patient reports must remain attributed; lab flags/ranges may support descriptive
concerns without implying a diagnosed disease. Unsupported edges remain subject to
condition verification. Models and request limits are unchanged. Condition and
narrative cache versions change, not the record extraction version.

Offline regression fixtures cover unreviewed eye history and flagged LDL reaching
organization, provenance preservation, and stale/contradicted exclusion. These test
routing and contracts, not live model clinical quality; the actual patient result
still needs device validation. Later manual review can guide conflict resolution,
with prior dated history retained rather than erased.

Device feedback on commit `1f6b618` (September 27): the user reports a much better
version after restoring source-linked eligibility. This is partial validation,
not confirmation of complete clinical coverage: the cholesterol concern is still
missing. Follow-up must determine whether the cholesterol readings, flags, and
reference ranges survived extraction and eligibility, or whether organization or
condition verification omitted them. Do not mark that omission resolved without
checking the actual evidence path.

### Explicit lab-row preservation

Recognized, fully labelled lab rows now produce drafts deterministically: test
name, result, source reference range, explicit above/below-range flag, and dated
order context. A dash for a missing range remains unset, including fasting-hours
rows adjacent to lipid results. Ambiguous layouts use the existing model extractor.
No diagnosis or treatment advice is derived from report boilerplate. Drafts still
pass the existing classification and source-checking stages, with unchanged limits.

Local parser validation against the supplied report retained both dated elevated
LDL readings and did not flag either HDL reading. Only anonymized synthetic
fixtures are committed. This validates extraction coverage, not live condition
model output. Existing stored summaries need regeneration for that original report
using its menu; the change does not force reprocessing of unrelated records.

### Overview reference contract

Device feedback confirms the LDL concern now appears alongside the eye concern,
but overview generation reported invalid sentence links. Narrative schemas now
restrict factIDs to the submitted request's IDs, including each condensation batch,
and require at least one reference per sentence. Local reference and numeric checks
remain in place. Numeric grounding failures now report unsupported content rather
than incorrectly reporting invalid links. No record extraction or condition cache
migration is needed; retry Create overview after rebuilding. Offline schema tests
and compilation do not substitute for verifying the next device-generated narrative.
