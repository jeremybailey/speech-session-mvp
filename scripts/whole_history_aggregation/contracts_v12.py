"""Single-request B fidelity iteration; no answer-key content enters inference."""
import json
import contracts_v11 as previous
VERSION='source-assertion-fidelity-v1'
MODEL=previous.MODEL; OUTPUT_TOKENS=previous.OUTPUT_TOKENS; CONTEXT_TOKENS=previous.CONTEXT_TOKENS
install=previous.install
INSTRUCTIONS=previous.INSTRUCTIONS.replace('OUTPUT ORDER: concerns, overview, passages. First read the whole bundle and plan independently supported clinical concerns. Then give a brief source-supported overview. Finally extract every original passage\'s atomic facts.', 'OUTPUT ORDER: concerns, passages, overview. First read the whole bundle and plan independently supported clinical concerns. Extract every original passage\'s atomic facts. Then write the overview from that extracted inventory.')
INSTRUCTIONS+='''

ASSERTION FIDELITY PRIORITY: A concise inventory must retain the source's actual assertion, not just its topic. Preserve the distinction between explaining that two things differ and stating the actual conclusion of that explanation. Likewise, mention of an option is not a patient preference or a decision. Record a preference, refusal, uncertainty, unanswered question, reassurance or conditional decision explicitly when present, with its speaker and encounter context. Preserve negative conclusions as carefully as positive ones.

Do not silently make source language more specific. Use an unspecified substance, body fluid, bleeding origin, uncertain product name, incompletely readable identifier or unnamed practitioner as unspecified/uncertain. A familiar clinical explanation is not evidence. Keep a patient asking whether a behavior occurs distinct from reporting that it occurs. A patient's report of another person's view keeps that nested attribution. If speaker identity is not recoverable, by must be unclear; do not assign a clinician merely because advice sounds clinical. Context from another original never supplies a missing actor, date, diagnosis or qualifier in this original.

For each extracted assertion, retain its explicit quantities, duration, laterality, comparison, change over time, uncertainty, rationale, limits and alternatives. Do not round a source's stated interval into a generic interval when exact wording is available. Preserve whether a result callback is promised for all results or only some results. Separate the person's planned action from the clinic's action. Keep no-benefit statements distinct from benefit-not-recorded statements. Do not replace a specific limiting instruction with a vague reassuring one. Preserve distinct failed treatment attempts rather than merging the list into unspecified prior treatment.

Clinical logistics are part of care: keep referrals, who referred to whom, missing intake/paperwork affecting care, unsuccessful attempts to reach care, appointments, remaining-session limits, named organizations and provider roles. Preserve medication label identifiers and incomplete label text without guessing missing characters. These belong to the original's inventory rather than only its citations. Do not copy general social/administrative material with no clinical relevance merely to increase detail count.

Use concise clinical wording and put decision-changing qualifiers in text or the action's p metadata; do not rely on raw source quotations to carry information omitted from the extracted inventory. Re-read each original for omissions before finalizing its passages. Then check every assertion against its cited text for specificity, uncertainty, numerical fidelity and attribution. Write overview last, from the retained facts, with no new clinical inference. This audit is part of the same single request, not another paid processing step. Never output a self-assigned accuracy score or claim independent verification.
'''
CHECK_INSTRUCTIONS=INSTRUCTIONS+'\nNo independent paid checker is used.'

def bundle(records):
    data,table=previous.bundle(records);data['version']=VERSION;return data,table

def schema_for(records):
    schema=previous.schema_for(records)
    schema['properties']={k:schema['properties'][k] for k in ('concerns','passages','overview')}
    schema['required']=list(schema['properties'])
    return schema

def configure(records):
    global SCHEMA
    SCHEMA=schema_for(records)

def payload(records,proposal=None):
    if proposal is not None:raise ValueError('single_request_only')
    data,_=bundle(records)
    p={'stage':'whole-history-generation','instructions':INSTRUCTIONS,'input':json.dumps(data,ensure_ascii=False,separators=(',',':')),'response_format':{'type':'json_schema','json_schema':{'name':'source_assertion_fidelity','strict':True,'schema':schema_for(records)}}}
    upper=len(json.dumps(p,ensure_ascii=False).encode())+4096
    if upper+OUTPUT_TOKENS>CONTEXT_TOKENS:raise ValueError('context_limit_exceeded')
    return p,{'inputTokenUpperBound':upper,'outputAllowance':OUTPUT_TOKENS,'contextLimit':CONTEXT_TOKENS,'version':VERSION}

def resolve(result,records):
    out,audit=previous.resolve(result,records);audit['version']=VERSION
    return out,audit

def validate(result,records):return resolve(result,records)[1]
