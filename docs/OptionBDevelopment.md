# Option B development fork

The fallback is branch `codex/pre-option-b-fallback-2026-11-02` at commit `9be4b9c18b76eede655bb94becf31282518becda`. This development branch starts directly from that snapshot, preserving its combined care-plan and recovery work.

## Current candidate

B reads source-only copies of saved records in one whole-history call. A second dedicated overview-writing call uses B's proposals and condition links. Both calls use Luna with medium reasoning. The overview targets 70–90 words, with a 100-word phone limit, and automatic all-condition coverage decisions; it has no patient-selected or patient-specific priority defaults.

The phone preview includes source-linked details, care-plan occurrences, a compact overview and conditions grouped by body system. Systems are ordered by concern count descending; ties preserve their original order. Existing cached results can be viewed without new inference.

## Source entry points

- `SpeechSessionApp/WholeHistoryBTrial.swift`: read-only phone trial, resumable identities, local validation, source quotations and preview navigation.
- `scripts/whole_history_aggregation/contracts_v13.py`: the phone's initial B contract, based on the earlier compact-actions version.
- `scripts/whole_history_aggregation/phone/contract.ts`: source-only TypeScript bundle/payload builder.
- `scripts/whole_history_aggregation/phone/overview_v6.ts`: current general-purpose compact overview prompt and response schema.
- `scripts/whole_history_aggregation/phone/endpoint_v7.ts`: current scoped diagnostic endpoint source.
- Earlier contract and endpoint versions remain for reproducibility; they are not the active policy.

## Build and preview

Open `SpeechSessionApp.xcodeproj` in this checkout and select the `Whole-history B Phone` scheme with Debug. Open Settings → Experiments → Whole-history B trial. Body-system previews are beneath the two-pass overview and also accessible through Conditions by body system.

The local `SpeechSessionApp/WholeHistoryB.local.json` is ignored and excluded from this commit. It contains expiring diagnostic access, not a production provider key. A clean checkout needs fresh private configuration before paid runs; do not commit it or include it in a Release build. The existing configured phone checkout can continue to use its local configuration until it expires.

The diagnostic endpoint/template are materialized into a private backend copy for testing; do not add the historical endpoint variants to production routes directly. Existing preparation scripts retain frozen historical experiment paths, so adapting their local paths is required when replaying on another machine.

## Status and limits

This is a development fork of the tested B preview, not a production processing switch. The normal app still uses the existing pipeline. B outputs remain unverified proposals and are not imported into checked patient data. Reference integrity and coverage bookkeeping do not establish clinical accuracy.

The latest compact overview passed five targeted cases (one cached patient result and four synthetic histories), including native source, citation, number, coverage and length checks. These small checks do not establish population-level accuracy. Private records, answer keys, outputs and grading artifacts remain in ignored benchmark storage.

The existing cumulative $5 experiment allowance, shared pilot cap, historical charges and unresolved reservations are unchanged. Forking these branches does not authorize resetting budgets, changing production domains or releasing an app.
