# Whole-history QA gates

This checklist records evidence, not a claim that every bug has been found. Installed version: build 52; live backend category-balanced-v14 with repeatable context notes and explicit saved-result revalidation. Unshipped scoped candidate v19 remains under evaluation. Private records and outputs remain under ignored benchmark storage.

| Gate | Evidence | Status |
| --- | --- | --- |
| Real phone saved history remains visible during recovery | Mirroring inspection November 5; 20 original texts and IDs matched post-install | Passed for tested history |
| App background/return resumes same run | November 4 phone replay retained parent identity after background allowance expired | Passed for one run; repeat after final repair pending |
| Generation and overview recover without holding a function open | Both stages use durable provider receipt; local fake-provider/database fault suite | Passed synthetic; live overview background confirmation pending |
| Queue redelivery does not resubmit inference | Pending and completed redelivery, ambiguous 503, interrupted retrieval and settlement tests | Passed synthetic |
| Rejections do not leave reservations stuck | Seven definitive HTTP rejection statuses settle zero inference usage; no redispatch | Passed synthetic |
| Cancel, duplicate, budget exhaustion, expiry and uncertain accounting | Full backend suite with fresh PostgreSQL databases | Passed automated |
| Response validity agrees on server and phone | Actual v14 generation and writer pass shared Swift validators; latest failed 372-row response passes corrected server validator; shared app/server context fixtures pass | Passed for one private replay |
| Original records and saved history survive partial output | Source equality and category-retention tests; phone shows three retained records | Passed preservation; completeness unresolved |
| Every material source assertion survives | One confirmed work/time-availability omission; full individual grading outstanding | Not passed |
| Legacy category migrations do not cause false failures | Two previous test categories now appear as counselling/future care | Review required |
| Medication/contact/lab/care-plan entity formatting | Existing presentation tests and prior device iterations | Full final visual sweep pending |
| Overview contains supported dates/numbers and material conditions | Shared narrative contract passes actual writer; withheld on incomplete publication | Passed validation; final phone publication pending |
| User sees clear state without contradictory success/errors | Build 50 retained-record list, old/new comparison and source disclosure inspected on phone; return navigation passed; acceptance unexercised | Partial |
| Runtime and cost remain acceptable | v14 private replay 408.906 seconds, $0.0345832; no extra inference added by durability fix | No speed improvement established |
| Clinical grading | Frozen answer key remains Draft; expected details, conditions and relationships need individual review | Provisional |
| Diagnostics cleanup | Prior 10 plus current nine temporary deployments removed; seven current scoped payloads removed, accounting retained, $0.2388374 spent / $0 reserved | Passed current cleanup |

Do not clear these gates by disabling source/reference validation, dropping old data silently, treating normal labs as noise, or accepting an omitted category as complete. A green automated suite alone does not satisfy source-completeness or real-device gates.


### Build 53 checkpoint

- Saved overview replay passes the real Swift decoder; uncited secondary coverage is neutral bookkeeping, with no citation/prose edits or paid rewrite.
- Full Swift suite: 497 tests, three skipped, zero failures; focused backend contract/recovery: 67 passed; typecheck passed. Build 53 installed and review-gate UI observed.
- Exact post-install receipt identity is not reconciled: the later container copy differs from the Mirroring screen. Do not claim a fully verified end-to-end publication from that copy.
- Offline review of the earlier 372-fact response found a measured-results passage discarded as nonclinical, future-test/screening category migrations, and a vitamin intervention categorized as vaccination. These remain semantic QA failures/review items. The private per-record review is ignored benchmark storage; no source or answer-key expectations changed.
- No retained category change accepted automatically. Clinical completeness and final publication remain open.
