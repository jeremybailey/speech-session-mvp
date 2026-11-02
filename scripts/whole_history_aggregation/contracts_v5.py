"""Fixed-column structured arrays reduce wire overhead without dropping fields."""
import json
from collections import defaultdict
import contracts as v1
import contracts_v4 as v4

VERSION = 'passage-columns-local-cards-v1'
MODEL = v1.MODEL
OUTPUT_TOKENS = v1.OUTPUT_TOKENS
CONTEXT_TOKENS = v1.CONTEXT_TOKENS
SCHEMA = None
COLUMNS = {
    'passageFact': ['category', 'text', 'by', 'status', 'event', 'contextIDsCSV', 'planOwner', 'planFollowUp', 'planConsiderations'],
    'condition': ['id', 'name', 'systemsCSV', 'sectionsCSV', 'factIDsCSV'],
    'relationship': ['id', 'sourceID', 'relation', 'targetID'],
    'overview': ['text', 'factIDsCSV'],
}
INSTRUCTIONS = v4.INSTRUCTIONS + '''

WIRE FORMAT (authoritative): The input includes outputColumns. Return the same facts/metadata using fixed-column STRING ARRAYS to avoid repeated JSON field names. Do NOT return fact or condition objects. Under each required passage key, return an array of fact rows, with each row exactly NINE strings in this order:
[category, text, by, status, event, contextIDsCSV, planOwner, planFollowUp, planConsiderations].
The first fact row under r1.p3 has ID r1.p3.1, the second r1.p3.2. Record identity and primary citation are still assigned locally. contextIDsCSV is empty or at most two additional same-record passage IDs separated by commas. Do not include the primary containing passage in context. Do not put care-plan ownership into the by/speaker column: preserve both correctly.

For a wholly nonclinical/other-person/unintelligible passage return exactly ONE sentinel row: [reason,"","","","","","","",""] where reason is nonclinical, other_person or unintelligible. Never mix a sentinel with fact rows. Every passage has at least one row. Empty rows and missing passages are invalid. Any clinically relevant information requires real fact rows; do not hide clinical content in a sentinel.

Allowed clinical categories: medications, carePlan, symptoms, findings, contacts, other. Allowed status values: reported, observed, negative, historical, resolved, prescribed, recommended, conditional, declined, performed, planned, unclear. Fact text is still ONE atomic fact/action, maximum 360 characters. Preserve all original qualifiers; this compact format is not permission to summarize or skip facts. Return enough fact rows to capture every distinct clinically meaningful item in each source passage, including long/duplicate records and each individual lab result. Use empty strings for absent metadata; NEVER replace unknown data with guessed values.

The last three columns contain plan metadata for actionable carePlan facts or medication directions in prescribed/recommended/conditional/planned status. All three may be empty if those plan details are unknown; the application still creates an action card with unknown owner/timing rather than guessing. For all other fact categories, medication history or past performed interventions, the last three columns MUST be empty. Do not infer future tasks from prior treatments.

conditions is an array of FIVE-string rows [id,name,systemsCSV,sectionsCSV,factIDsCSV]. relationships is an array of FOUR-string rows [id,sourceID,relation,targetID]. overview is an array of TWO-string rows [text,factIDsCSV]. CSV here means comma-separated identifiers/labels, without extra JSON or quoted lists; use empty strings for empty optional lists. All referenced fact IDs must exist as containing-passage/row identities. Do not produce cards or quotation strings; they are built locally. Only root fields passages, conditions, relationships and overview are allowed. Before returning, check row order, all fixed column counts, ID links, speaker/actor distinctions, negation, dates, qualifiers and each excluded passage.'''
CHECK_INSTRUCTIONS = INSTRUCTIONS + '\nNo independent paid checker is used.'


def bundle(records):
    source, table = v1.bundle(records)
    source.update(version=VERSION, outputColumns=COLUMNS)
    return source, table


def rows(length):
    return v1.arr({'type': 'array', 'items': v1.S, 'minItems': length, 'maxItems': length})


def schema_for(records):
    _, table = bundle(records)
    fact_rows = rows(9)
    fact_rows['minItems'] = 1
    return v1.obj(passages=v1.obj(**{pid: fact_rows for pid in table}), conditions=rows(5), relationships=rows(4), overview=rows(2))


def configure(records):
    global SCHEMA
    SCHEMA = schema_for(records)


def payload(records, proposal=None):
    if proposal is not None:
        raise ValueError('single_request_only')
    source, _ = bundle(records)
    p = {'stage': 'whole-history-generation', 'instructions': INSTRUCTIONS,
         'input': json.dumps(source, ensure_ascii=False, separators=(',', ':')),
         'response_format': {'type': 'json_schema', 'json_schema': {'name': 'passage_fact_columns', 'strict': True, 'schema': schema_for(records)}}}
    upper = len(json.dumps(p, ensure_ascii=False).encode()) + 4096
    if upper + OUTPUT_TOKENS > CONTEXT_TOKENS:
        raise ValueError('context_limit_exceeded')
    return p, {'inputTokenUpperBound': upper, 'outputAllowance': OUTPUT_TOKENS, 'contextLimit': CONTEXT_TOKENS,
               'version': VERSION, 'documentation': 'https://developers.openai.com/api/docs/models/gpt-6-luna'}


def csv(value):
    if not isinstance(value, str):
        raise ValueError('non_string_column')
    if not value:
        return []
    result = [x.strip() for x in value.split(',')]
    if any(not x for x in result):
        raise ValueError('empty_csv_reference')
    return result


def row_shape(row, length):
    if not isinstance(row, list) or len(row) != length or any(not isinstance(x, str) for x in row):
        raise ValueError('invalid_column_count_or_type')


def resolve(result, records):
    if not isinstance(result, dict) or set(result) != {'passages', 'conditions', 'relationships', 'overview'}:
        raise ValueError('malformed_object')
    _, table = bundle(records)
    if not isinstance(result['passages'], dict) or set(result['passages']) != set(table):
        raise ValueError('missing_or_invented_passage')
    typed = {'passages': {}, 'conditions': [], 'relationships': [], 'overview': []}
    events = {}
    for pid in table:
        values = result['passages'][pid]
        if not isinstance(values, list) or not values:
            raise ValueError('empty_passage_rows')
        facts, disposition = [], 'used'
        for n, row in enumerate(values, 1):
            row_shape(row, 9)
            category, text, by, status, event, context, owner, timing, considerations = row
            if category in ('nonclinical', 'other_person', 'unintelligible'):
                if len(values) != 1 or any(row[1:]):
                    raise ValueError('clinical_content_in_exclusion')
                disposition = category
                continue
            if status not in ('reported', 'observed', 'negative', 'historical', 'resolved', 'prescribed', 'recommended', 'conditional', 'declined', 'performed', 'planned', 'unclear'):
                raise ValueError('invalid_status')
            action = category == 'carePlan' and status not in ('performed', 'historical', 'observed')
            direction = category == 'medications' and status in ('prescribed', 'recommended', 'conditional', 'planned')
            if (owner or timing or considerations) and not (action or direction):
                raise ValueError('non_action_plan_metadata')
            plan = dict(owner=owner, followUp=timing, considerations=considerations) if action or direction else None
            facts.append(dict(category=category, text=text, by=by, status=status, event=event, context=csv(context), plan=plan))
            events[f'{pid}.{n}'] = event
        typed['passages'][pid] = dict(disposition=disposition, facts=facts)
    for row in result['conditions']:
        row_shape(row, 5)
        typed['conditions'].append(dict(id=row[0], name=row[1], systems=csv(row[2]), sections=csv(row[3]), details=csv(row[4])))
    for row in result['relationships']:
        row_shape(row, 4)
        typed['relationships'].append(dict(id=row[0], source=row[1], relation=row[2], target=row[3]))
    for row in result['overview']:
        row_shape(row, 2)
        typed['overview'].append(dict(text=row[0], details=csv(row[1])))
    expanded, audit = v4.resolve(typed, records)
    by_id = {d['id']: d for d in expanded['details']}
    cards = []
    for card in expanded['carePlans']:
        # Unknown event dates do not establish that relative follow-ups in
        # different originals are the same task. Exact duplicate originals may
        # still share a card, retaining every source-backed occurrence.
        partitions = defaultdict(list)
        for fid in card['occurrenceIDs']:
            pid = fid.rsplit('.', 1)[0]
            temporal_key = ('event', events[fid]) if events[fid] else ('original', table[pid]['sourceSHA256'])
            partitions[temporal_key].append(fid)
        for fids in partitions.values():
            row = dict(card)
            row['id'] = card['id'] + '@' + fids[0]
            row['occurrenceIDs'] = fids
            refs = {}
            for fid in fids:
                for ref in by_id[fid]['sources']:
                    refs[(ref['recordID'], ref['quote'])] = ref
            row['sources'] = list(refs.values())
            cards.append(row)
    expanded['carePlans'] = cards
    audit.update(version=VERSION, localCareCardCount=len(cards), wireFormat='Fixed validated string columns; no missing fields or implicit ID guesses',
                 unknownDateGrouping='Separate different original hashes when event date unknown')
    return expanded, audit


def validate(result, records):
    return resolve(result, records)[1]
