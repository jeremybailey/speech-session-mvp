"""Compact core columns, typed evidence/owner fields, deterministic local cards."""
import copy
import json
import re
from collections import defaultdict
import contracts as v1
import contracts_v4 as v4

VERSION = 'passage-typed-columns-local-cards-v1'
MODEL = v1.MODEL
OUTPUT_TOKENS = v1.OUTPUT_TOKENS
CONTEXT_TOKENS = v1.CONTEXT_TOKENS
SCHEMA = None
INSTRUCTIONS = v4.INSTRUCTIONS + '''

COMPACT TYPED WIRE FORMAT (authoritative): Every original passage key is required. A wholly nonclinical/other-person/unintelligible passage returns just the corresponding STRING nonclinical, other_person or unintelligible. A passage with clinical content returns a nonempty ARRAY of fact objects. Do not mix an exclusion with facts. Each fact object has exactly THREE keys:
  v: [category, text, by, status, event] -- exactly five strings in this order;
  c: an array of zero, one or two additional SAME-RECORD context passage IDs;
  p: null, or {owner, followUp, considerations} for a source-backed action.
The containing passage is automatically the primary citation; do not repeat it in c. NEVER put source passage IDs in the plan-owner field. The first fact under r1.p3 has ID r1.p3.1, the second r1.p3.2, etc., assigned locally. Do not output fact IDs, record IDs, quotations or care-plan cards.

Allowed categories: medications, carePlan, symptoms, findings, contacts, other. Allowed status: reported, observed, negative, historical, resolved, prescribed, recommended, conditional, declined, performed, planned, unclear. text is ONE atomic fact/action, maximum 360 characters, preserving qualifiers and uncertainties. Do not summarize whole passages containing several distinct facts or skip duplicate records. Include each clinically meaningful fact, negative, patient care contact and individual lab value. Keep metadata in its correct column. No clinical data, actor, unit, active ingredient, fluid type, diagnosis or date may be supplied from assumption.

p is null for symptoms, findings, ordinary contacts, general counselling, past performed interventions and medication-use history. For an actual future/conditional care instruction, follow-up appointment, promised clinician call or medication direction, p contains the action owner, follow-up timing and considerations exactly supported by source; leave missing values empty. Contact- or other-labelled follow-up actions may have p only with planned/recommended/conditional/prescribed status. Medication directions may have p only with prescribed/recommended/conditional/planned status. carePlan facts require p unless they describe historical or performed care. A performed intervention is not a future task. The owner is the person who should act, not simply the speaker in by. Never change uncertainty into agreement or attach a generic symptom to a plan. The local projector preserves the original model category and records action-category compatibility separately.

conditions, relationships and overview retain their compact object form from the schema. Conditions have id/name/systems/sections/details; relationships have id/source/relation/target; overview has text/details. Every linked fact ID must exist in the passage arrays. Locally derived sources do not excuse unsupported condition labels, causal claims or links. Only root fields passages, conditions, relationships and overview. Before returning, check each source passage for omissions and every claim for attribution, negation, dates, qualifiers, ownership and entailment. This is an unverified proposal, not checked patient data.'''
CHECK_INSTRUCTIONS = INSTRUCTIONS + '\nNo independent paid checker is used.'


def bundle(records):
    source, table = v1.bundle(records)
    source.update(version=VERSION, coreColumns=['category', 'text', 'by', 'status', 'event'])
    return source, table


def schema_for(records):
    _, table = bundle(records)
    schema = v4.schema_for(records)
    fact = v1.obj(v={'type': 'array', 'items': v1.S, 'minItems': 5, 'maxItems': 5},
                  c={'type': 'array', 'items': v1.S, 'maxItems': 2},
                  p={'anyOf': [{'type': 'null'}, v1.obj(owner=v1.S, followUp=v1.S, considerations=v1.S)]})
    schema['$defs'] = {'fact': fact, 'excluded': {'type': 'string', 'enum': ['nonclinical', 'other_person', 'unintelligible']}}
    schema['properties']['passages'] = v1.obj(**{pid: {'anyOf': [
        {'$ref': '#/$defs/excluded'}, {'type': 'array', 'items': {'$ref': '#/$defs/fact'}, 'minItems': 1}]} for pid in table})
    return schema


def configure(records):
    global SCHEMA
    SCHEMA = schema_for(records)


def payload(records, proposal=None):
    if proposal is not None:
        raise ValueError('single_request_only')
    source, _ = bundle(records)
    p = {'stage': 'whole-history-generation', 'instructions': INSTRUCTIONS,
         'input': json.dumps(source, ensure_ascii=False, separators=(',', ':')),
         'response_format': {'type': 'json_schema', 'json_schema': {'name': 'typed_passage_columns', 'strict': True, 'schema': schema_for(records)}}}
    upper = len(json.dumps(p, ensure_ascii=False).encode()) + 4096
    if upper + OUTPUT_TOKENS > CONTEXT_TOKENS:
        raise ValueError('context_limit_exceeded')
    return p, {'inputTokenUpperBound': upper, 'outputAllowance': OUTPUT_TOKENS, 'contextLimit': CONTEXT_TOKENS,
               'version': VERSION, 'documentation': 'https://developers.openai.com/api/docs/models/gpt-6-luna'}


def resolve(result, records):
    if not isinstance(result, dict) or set(result) != {'passages', 'conditions', 'relationships', 'overview'}:
        raise ValueError('malformed_object')
    _, table = bundle(records)
    if not isinstance(result['passages'], dict) or set(result['passages']) != set(table):
        raise ValueError('missing_or_invented_passage')
    typed = {k: copy.deepcopy(result[k]) for k in ('conditions', 'relationships', 'overview')}
    typed['passages'] = {}
    events, categories, reclassified = {}, {}, {}
    for pid in table:
        rows = result['passages'][pid]
        if isinstance(rows, str):
            if rows not in ('nonclinical', 'other_person', 'unintelligible'):
                raise ValueError('invalid_exclusion')
            typed['passages'][pid] = {'disposition': rows, 'facts': []}
            continue
        if not isinstance(rows, list) or not rows:
            raise ValueError('empty_passage_rows')
        facts = []
        for n, row in enumerate(rows, 1):
            if not isinstance(row, dict) or set(row) != {'v', 'c', 'p'} or not isinstance(row['v'], list) or len(row['v']) != 5 or any(not isinstance(x, str) for x in row['v']):
                raise ValueError('invalid_core_columns')
            category, text, by, status, event = row['v']
            if status not in ('reported', 'observed', 'negative', 'historical', 'resolved', 'prescribed', 'recommended', 'conditional', 'declined', 'performed', 'planned', 'unclear'):
                raise ValueError('invalid_status')
            fid = f'{pid}.{n}'
            categories[fid] = category
            plan = copy.deepcopy(row['p'])
            if plan is not None:
                v1.validate_shape(plan, v1.obj(owner=v1.S, followUp=v1.S, considerations=v1.S))
                if re.fullmatch(r'r\d+\.p\d+(?:\.\d+)?', plan['owner']):
                    raise ValueError('source_locator_is_not_plan_owner')
                if category in ('contacts', 'other') and status in ('planned', 'recommended', 'conditional', 'prescribed'):
                    reclassified[fid] = category
                    category = 'carePlan'
            facts.append(dict(category=category, text=text, by=by, status=status, event=event, context=copy.deepcopy(row['c']), plan=plan))
            events[fid] = event
        typed['passages'][pid] = {'disposition': 'used', 'facts': facts}
    expanded, audit = v4.resolve(typed, records)
    by_id = {d['id']: d for d in expanded['details']}
    for fid in reclassified:
        by_id[fid]['category'] = categories[fid]
    cards = []
    for card in expanded['carePlans']:
        partitions = defaultdict(list)
        for fid in card['occurrenceIDs']:
            pid = fid.rsplit('.', 1)[0]
            key = ('event', events[fid]) if events[fid] else ('original', table[pid]['sourceSHA256'])
            partitions[key].append(fid)
        for fids in partitions.values():
            row = dict(card); row['id'] = card['id'] + '@' + fids[0]; row['occurrenceIDs'] = fids
            refs = {(ref['recordID'], ref['quote']): ref for fid in fids for ref in by_id[fid]['sources']}
            row['sources'] = list(refs.values()); cards.append(row)
    expanded['carePlans'] = cards
    audit.update(version=VERSION, localCareCardCount=len(cards), actionCategoryCompatibility=reclassified,
                 wireFormat='Five core columns plus separately typed context and plan fields',
                 unknownDateGrouping='Separate different original hashes when event date unknown')
    return expanded, audit


def validate(result, records):
    return resolve(result, records)[1]
