# Experimental whole-history B

This is an isolated single-request development experiment. It does not change
the app, production processing, or checked patient data. The previous A/B/C
artifacts and original dirty checkouts remain unchanged.

The input is a lossless partition of the original saved text, preserving record
identity, saved metadata, hashes, passage order and character offsets. B returns
compact passage IDs instead of regenerating quotations. The local resolver
rejects invented IDs, cross-record evidence, broken entity links, non-plan
care-card occurrences and missing/contradictory coverage dispositions. Resolved
quotations always come from the exact original. This establishes reference
integrity only; the model may still cite a passage that does not support its
claim or incorrectly exclude a relevant passage.

The prompt requests an atomic inventory rather than broad summaries, preserving
negation, uncertainty, dates, medication qualifiers, attribution and care-plan
ownership. A record review ledger exposes every passage not used by details.
No numerical detail target is imposed and no answer-key expectations or prior
generated output enter inference.

Keep Luna medium, 64,000 output tokens including reasoning, the documented
1,050,000 context limit, and the diagnostic 270-second provider deadline. Every
explicit development run has a fresh owner. Duplicate submissions within a run
remain idempotent. There is no automatic paid retry, splitting, checker or repair.
The diagnostic admission gate counts every historical job under the original
experiment prefix against the original cumulative $5 cap, including uncertain
reservations. Never increase or reset that cap or the shared $20 pilot limit.

Before paid work: run the synthetic resolver tests and local ledger tests,
typecheck the isolated backend, deploy authenticated diagnostics with no domain
assignment, verify historical accounting and freeze source/prompt/schema/key
hashes. Artifacts and clinical data belong only in ignored `build/benchmarks/`.

Evaluate the unchanged frozen expectations separately after generation. Compare
core presence and qualifiers against the prior fixed-build A detail output;
grade conditions, links, dates, attribution, negation and plan ownership explicitly.
Review unmatched additions, omitted passages and each care card against originals.
Do not turn a correct quotation, complete coverage ledger or a higher detail count
into a clinical accuracy pass. Do not reward unsupported extra detail. All Draft
labels stay provisional and conflicting duplicate C001 rows remain excluded.

The prior A run failed at condition mapping; its 29m58s is not a successful
end-to-end baseline. A new B may establish feasibility and provisional detail
comparison, but cannot prove overall equivalence to a completed A or qualify for
rollout until material regressions are resolved and repeated completed runs exist.

Afterward remove diagnostic deployments and temporary credentials and purge only
this trial's remote payloads. Retain accounting, unresolved charges, manifests,
outputs and individual review evidence. Verify production aliases unchanged.


Current entry point: `experiment_v11.py` with `contracts_v11.py`.
It retains the 12 app categories, creates concern identities before extraction,
and projects exact quotations and care cards locally. Care actions use the
state at the source encounter; recommendations cannot be labelled resolved.
All care states retain actor/timing metadata. Paired lossless passages reduce
schema and output bookkeeping without changing original text or record IDs.
Compact action metadata is decoded without rewriting clinical assertions.

Run `python3 -m unittest discover -s scripts/whole_history_aggregation -p
'test_contracts*.py'` before preparation. The original experiment allowance is
cumulative across every development version, including unresolved outcomes.
Source/schema versions already frozen for a paid run must remain immutable.

Known review findings in the earlier concern-first version: source-valid
quotations did not prevent unsupported specificity about body fluid or bleeding
origin; many recommendations were incorrectly labelled resolved. Those runs
are not clinical successes. The source-state version then hit the provider
deadline, so it provides no evidence of improved clinical accuracy. See ignored
private experiment artifacts for run receipts and individual review evidence.


Development direction (2 November): prioritize B as the candidate architecture.
The current fidelity experiment is `experiment_v12.py` / `contracts_v12.py`.
It keeps the one-request design and paired source spans, strengthens assertion
specificity/uncertainty/qualifier and clinical-logistics retention, and orders
overview after the extracted inventory. It introduces no production route or
patient-data import. Prompt changes contain general rules, never expected key
items or patient-specific examples. Retest against the unchanged offline key;
do not infer improvement from the prompt or its local compatibility checks.


Current phone development fork (2 November): initial contract v13; compact overview `phone/overview_v6.ts`; scoped endpoint `phone/endpoint_v7.ts`. The overview is a second Luna/medium call, with 70–90 target words and a 100-word phone limit. See `docs/OptionBDevelopment.md` for the branch and source entry points. Historical versions above remain frozen references.
