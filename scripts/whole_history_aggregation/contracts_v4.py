"""Compact passage facts plus local cards/citations; still one inference request.

Local projection does not verify clinical meaning. It never fills missing owners,
dates or claims and combines only exactly equivalent same-status plan metadata.
"""
import copy
import json
import contracts as v1
import contracts_v3 as v3

VERSION = 'passage-facts-local-cards-v1'
MODEL = v1.MODEL
OUTPUT_TOKENS = v1.OUTPUT_TOKENS
CONTEXT_TOKENS = v1.CONTEXT_TOKENS
SCHEMA = None
INSTRUCTIONS = v3.INSTRUCTIONS.split('Return care-plan cards with unique p-numbers.')[0] + '''
COMPACT PLAN FORMAT: Do NOT output care-plan cards, titles, repeated action prose or repeated citation text. For each actionable carePlan fact, set plan to {owner, followUp, considerations}; text already states the full action. owner is the person responsible for doing the action, not merely the speaker: distinguish patient, clinician/team and unknown. Leave ownership/follow-up/considerations empty when the original does not establish them. Past performed interventions and explanatory counselling need plan=null; they must not become future tasks. A medication DIRECTION may have plan metadata only with prescribed/recommended/conditional/planned status. A generic medication history is plan=null. All other facts have plan=null. The application will create source-backed cards directly from action text and this metadata, with original occurrence IDs and local quotations. You must still extract each distinct action, precaution or option, with its actor, conditions and timing; do not compress them away because the application constructs cards.

Conditions return id, name, systems, sections and lists of returned PASSAGE_ID.INDEX detail IDs. The application derives their citation text from those linked original occurrences; do not repeat citation IDs in conditions. Preserve historical/self-reported/uncertain condition wording. Relationships return id, source, relation, target, with valid returned fact/condition IDs and a precise SOURCE-SUPPORTED relation. Do not add unsupported causal or diagnostic connections. The application derives the evidence locations from the endpoints; this does not excuse unsupported links. Overview paragraphs return text and returned fact IDs in details; their source references are reconstructed locally. No generated content is evidence for other generated content.

Your only root fields are passages, conditions, relationships and overview. Every original passage key is mandatory. Every used passage has one or more granular fact objects, every exclusion has no facts. Do not insert regenerated quotes, fact IDs, record IDs or cards into the fact objects. Keep all source negation, qualifiers, numerical results, medication directions, ambiguous wording and speaker identity. Do not skip repeated records. The result remains an experimental proposal requiring independent review, never checked patient data.'''
CHECK_INSTRUCTIONS = INSTRUCTIONS + '\nNo independent paid checker is used.'


def bundle(records):
    source, table = v1.bundle(records)
    source['version'] = VERSION
    return source, table


def schema_for(records):
    schema = v3.schema_for(records)
    schema['properties'].pop('carePlans')
    schema['required'].remove('carePlans')
    schema['$defs']['fact']['properties']['plan'] = {'anyOf': [
        {'type': 'null'}, v1.obj(owner=v1.S, followUp=v1.S, considerations=v1.S)]}
    schema['$defs']['fact']['required'].append('plan')
    for kind in ('conditions', 'relationships', 'overview'):
        schema['properties'][kind]['items']['properties'].pop('cite')
        schema['properties'][kind]['items']['required'].remove('cite')
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
         'response_format': {'type': 'json_schema', 'json_schema': {'name': 'passage_facts_local_cards', 'strict': True, 'schema': schema_for(records)}}}
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
    projected = copy.deepcopy(result)
    fact_sources, facts, plans = {}, {}, {}
    for pid in table:
        group = projected['passages'][pid]
        if not isinstance(group, dict) or set(group) != {'disposition', 'facts'} or not isinstance(group['facts'], list):
            raise ValueError('malformed_passage_result')
        for n, fact in enumerate(group['facts'], 1):
            if not isinstance(fact, dict) or set(fact) != {'category', 'text', 'by', 'status', 'event', 'context', 'plan'}:
                raise ValueError('malformed_fact')
            fid = f'{pid}.{n}'
            plan = fact.pop('plan')
            if plan is not None:
                v1.validate_shape(plan, v1.obj(owner=v1.S, followUp=v1.S, considerations=v1.S))
                if fact['category'] != 'carePlan' and not (fact['category'] == 'medications' and fact['status'] in ('prescribed', 'recommended', 'conditional', 'planned')):
                    raise ValueError('non_action_plan_metadata')
                if fact['status'] in ('performed', 'historical', 'observed'):
                    raise ValueError('past_intervention_projected_as_task')
                plans[fid] = plan
            elif fact['category'] == 'carePlan' and fact['status'] not in ('performed', 'historical', 'observed'):
                raise ValueError('missing_action_ownership_metadata')
            if not isinstance(fact['context'], list) or any(not isinstance(x, str) for x in fact['context']):
                raise ValueError('malformed_context')
            fact_sources[fid] = [pid, *fact['context']]
            facts[fid] = fact

    def source_union(ids, allowed):
        if not isinstance(ids, list) or not ids or len(ids) != len(set(ids)) or any(i not in allowed for i in ids):
            raise ValueError('invalid_entity_link')
        return list(dict.fromkeys(p for i in ids for p in allowed[i]))

    condition_sources = {}
    condition_links = {fid: [] for fid in facts}
    for condition in projected['conditions']:
        v1.validate_shape(condition, v1.obj(id=v1.S, name=v1.S, systems=v1.REFS, sections=v1.REFS, details=v1.REFS))
        condition['cite'] = source_union(condition['details'], fact_sources)
        if condition['id'] in condition_sources or condition['id'] in facts:
            raise ValueError('duplicate_entity_id')
        condition_sources[condition['id']] = condition['cite']
        for fid in condition['details']:
            condition_links[fid].append(condition['id'])
    endpoints = {**fact_sources, **condition_sources}
    for relationship in projected['relationships']:
        v1.validate_shape(relationship, v1.obj(id=v1.S, source=v1.S, relation=v1.S, target=v1.S))
        relationship['cite'] = source_union([relationship['source'], relationship['target']], endpoints)
    for paragraph in projected['overview']:
        v1.validate_shape(paragraph, v1.obj(text=v1.S, details=v1.REFS))
        paragraph['cite'] = source_union(paragraph['details'], fact_sources)

    # One card per distinct exact action/owner/timing/status/date/condition tuple.
    # Semantic similarity never merges records or silently drops occurrences.
    cards = {}
    for fid, plan in plans.items():
        fact = facts[fid]
        key = (fact['text'], plan['owner'], plan['followUp'], plan['considerations'], fact['status'], fact['event'], tuple(sorted(condition_links[fid])))
        if key not in cards:
            cards[key] = {'id': 'plan:' + fid, 'title': fact['text'], 'owner': plan['owner'], 'action': fact['text'],
                          'followUp': plan['followUp'], 'considerations': plan['considerations'],
                          'occurrences': [], 'conditions': condition_links[fid], 'cite': []}
        cards[key]['occurrences'].append(fid)
        cards[key]['cite'] = list(dict.fromkeys([*cards[key]['cite'], *fact_sources[fid]]))
    projected['carePlans'] = list(cards.values())
    expanded, audit = v3.resolve(projected, records)
    audit.update(version=VERSION, localCareCardCount=len(cards),
                 localProjection='Exact action/owner/timing/status/date/condition grouping only; no invented content or semantic verification')
    return expanded, audit


def validate(result, records):
    return resolve(result, records)[1]
