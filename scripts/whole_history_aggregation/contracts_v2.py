"""Second explicit development contract; v1 and its run remain immutable.

Structured output requires a disposition for every source passage. Compact fact
limits discourage whole-record summaries; semantic review remains mandatory.
"""
import copy
import json
from collections import defaultdict
import contracts as v1

VERSION = 'atomic-source-spans-v2'
MODEL = v1.MODEL
OUTPUT_TOKENS = v1.OUTPUT_TOKENS
CONTEXT_TOKENS = v1.CONTEXT_TOKENS
INSTRUCTIONS = v1.INSTRUCTIONS.replace(
    'Finally audit record coverage. recordReview must contain each original record exactly once, in order. Every original passage must either be cited by at least one detail from that record or be listed ONCE in excluded. Exclude a passage only if its entire content is nonclinical, exclusively about another person, or unintelligible; use the corresponding reason.',
    'Finally audit record coverage. passageReview has a required key for EVERY passage in the originals. Set it to used exactly when a detail from that record cites it. Otherwise choose nonclinical, other_person or unintelligible, only when the entire passage qualifies. Never both use and exclude a passage; there are no optional or omitted keys.'
) + '''

Additional extraction discipline: This is a granular inventory. A detail is ONE distinct clinical fact or action, not a whole record, visit, panel, list of diagnoses or collection of treatment options. Each detail text is at most 360 characters and cites at most three passages. Split unrelated actions and measurements into separate details. Keep every numeric result with its stated value, unit and reference interpretation as separate findings when present. Keep clinically meaningful counselling precautions and optional actions individually. Repeat the underlying occurrence in each original, including duplicate or near-duplicate records: never substitute a short 'duplicate history' summary or borrow a detail from another record.

Use separate details for medication history versus a clinician's instruction to start, stop or continue it. A card must cite returned carePlan-category action details; split medication instructions into carePlan details instead of attaching a general medication-history detail to a card. Each carePlan detail must occur in a card. A performed intervention remains performed, not advice to repeat it. Newborn-care counselling within a pregnancy record belongs to that care plan; it is not unrelated other-person history. Do not group unrelated actions such as blood testing, swimming and medication follow-up into one card merely because they share a visit or condition.

Do not add an active ingredient, measurement unit, fluid type, exact date, diagnosis, speaker name, current status or action ownership that is absent from the supporting text. Preserve unclear/OCR-truncated wording, including directions, instead of completing it from medical knowledge. If a source gives a number without a unit, say the unit is unstated. Avoid turning a patient's question or hypothesis into an established symptom, diagnosis, cause or finding. A common clinical inference is still an inference and must not be introduced. Don't infer current use from a dispensing label, normalize a nonstandard label into standard directions, or present a prescribed drug as taken.

Audit every excluded passage for clinical content before finishing. A passage with even one relevant patient fact, patient care contact or plan must be represented by detail(s) and marked used. Do not use other_person for an ambiguous speaker when a patient's account can be retained with unclear attribution. Preserve both clinicians' advice and patient preferences/declines without converting a discussion into an agreed plan. An exact source locator is not proof of entailment: read the cited text and check every qualifier.'''
CHECK_INSTRUCTIONS = INSTRUCTIONS + '\nThis experiment does not use an independent paid checking pass.'
SCHEMA = None


def bundle(records):
    source, table = v1.bundle(records)
    source['version'] = VERSION
    return source, table


def schema_for(records):
    schema = copy.deepcopy(v1.SCHEMA)
    schema['properties'].pop('recordReview')
    schema['required'].remove('recordReview')
    _, table = bundle(records)
    schema['properties']['passageReview'] = v1.obj(**{pid: {'$ref': '#/$defs/disposition'} for pid in table})
    schema['required'].append('passageReview')
    schema['$defs'] = {'disposition': {'type': 'string', 'enum': ['used', 'nonclinical', 'other_person', 'unintelligible']}}
    props = schema['properties']['details']['items']['properties']
    props['text'] = {'type': 'string', 'minLength': 1, 'maxLength': 360}
    props['category'] = {'type': 'string', 'enum': ['medications', 'carePlan', 'symptoms', 'findings', 'contacts', 'other']}
    props['cite'] = {'type': 'array', 'items': v1.S, 'minItems': 1, 'maxItems': 3}
    return schema


def configure(records):
    global SCHEMA
    SCHEMA = schema_for(records)


def payload(records, proposal=None):
    if proposal is not None:
        raise ValueError('single_request_only')
    source, _ = bundle(records)
    source['version'] = VERSION
    p = {'stage': 'whole-history-generation', 'instructions': INSTRUCTIONS,
         'input': json.dumps(source, ensure_ascii=False, separators=(',', ':')),
         'response_format': {'type': 'json_schema', 'json_schema': {'name': 'atomic_source_spans_v2', 'strict': True, 'schema': schema_for(records)}}}
    upper = len(json.dumps(p, ensure_ascii=False).encode()) + 4096
    if upper + OUTPUT_TOKENS > CONTEXT_TOKENS:
        raise ValueError('context_limit_exceeded')
    return p, {'inputTokenUpperBound': upper, 'outputAllowance': OUTPUT_TOKENS, 'contextLimit': CONTEXT_TOKENS,
               'version': VERSION, 'documentation': 'https://developers.openai.com/api/docs/models/gpt-6-luna'}


def resolve(result, records):
    if not isinstance(result, dict) or set(result) != (set(v1.SCHEMA['properties']) - {'recordReview'}) | {'passageReview'}:
        raise ValueError('malformed_object')
    source, table = bundle(records)
    review = result['passageReview']
    if not isinstance(review, dict) or set(review) != set(table) or any(v not in ('used', 'nonclinical', 'other_person', 'unintelligible') for v in review.values()):
        raise ValueError('missing_or_invalid_passage_disposition')
    for detail in result['details']:
        if not isinstance(detail.get('text'), str) or not 1 <= len(detail['text']) <= 360:
            raise ValueError('detail_length_limit')
        if not isinstance(detail.get('cite'), list) or not 1 <= len(detail['cite']) <= 3:
            raise ValueError('detail_evidence_limit')
    # A derived v1 coverage ledger contains only model-supplied dispositions;
    # this conversion never invents a reason, claim or missing source reference.
    converted = copy.deepcopy(result)
    converted.pop('passageReview')
    converted['recordReview'] = []
    for record in source['originalRecords']:
        groups = defaultdict(list)
        for p in record['passages']:
            if review[p['id']] != 'used':
                groups[review[p['id']]].append(p['id'])
        converted['recordReview'].append({'r': record['r'], 'excluded': [{'reason': k, 'passages': v} for k, v in groups.items()]})
    expanded, audit = v1.resolve(converted, records)
    plan_occurrences = {did for card in result['carePlans'] for did in card['occurrences']}
    if any(d['category'] == 'carePlan' and d['id'] not in plan_occurrences for d in result['details']):
        raise ValueError('care_plan_occurrence_missing_card')
    audit['version'] = VERSION
    return expanded, audit


def validate(result, records):
    return resolve(result, records)[1]
