"""Action metadata enforced by schema; app navigation derived from real codes."""
import copy
import json
import contracts as v1
import contracts_v6 as v6

VERSION = 'passage-action-schema-v1'
MODEL = v1.MODEL
OUTPUT_TOKENS = v1.OUTPUT_TOKENS
CONTEXT_TOKENS = v1.CONTEXT_TOKENS
SCHEMA = None
SYSTEMS = {
    'musculoskeletal': 'Pain & movement', 'eye': 'Eyes & vision', 'neurological': 'Brain & nerves',
    'cardiovascular': 'Heart & circulation', 'respiratory': 'Breathing', 'digestive': 'Digestion',
    'endocrine': 'Hormones & metabolism', 'reproductive': 'Reproductive health',
    'urinary': 'Bladder & urinary health', 'mental': 'Emotional wellbeing', 'skin': 'Skin',
    'immune': 'Immune health', 'ear': 'Ears & hearing', 'unknown': 'Other health concerns',
}
PAST = ['performed', 'historical', 'observed', 'resolved']
ACTION = ['reported', 'negative', 'prescribed', 'recommended', 'conditional', 'declined', 'planned', 'unclear']
INSTRUCTIONS = v6.INSTRUCTIONS + '''

ACTION-TYPED FORMAT (authoritative): Facts now have exactly k, s, v, c, p. k is the category; s is status; v is exactly [text, by, event], three strings. c remains an array of additional same-record context IDs. p remains null or the named owner/followUp/considerations object. For future/conditional carePlan actions the schema REQUIRES p as an object, with empty strings for information genuinely unknown. Historical, performed, observed or resolved carePlan facts have p=null. Never relabel an instruction as historical just to omit metadata. Source speaker by and action owner are distinct fields. Preserve the actual responsible actor and timing whenever the source establishes them; don't leave known data blank. Do not guess missing data.

The input provides the app's actual body-system codes and navigation titles. Conditions return id/name/systems/details ONLY; choose systems from those exact codes. Sections are derived locally. Organization must retain EACH independently source-supported concern; do not flatten distinct concerns into a life-stage, body-region or 'symptoms/labs' bucket. A historical condition and a separate current concern remain distinguishable. Do not apply an event, life stage or diagnosis from one original to other originals lacking it. Source-named clinical concerns, symptoms, qualified histories and self-reports may be descriptive groups; a prevention discussion or a hypothetical complication is not evidence that the disease is present. Keep source uncertainty in labels and don't add a substance, fluid, diagnosis or causal interpretation absent from source.

Return each clinical passage's full granular inventory, including patient care contacts, dispensing-pharmacy details and source-backed follow-up responsibilities. No medication label establishes actual use; a patient's name is not a clinician or prescriber. Independently named concerns should remain identifiable and all relevant fact occurrences should be linked without inventing connections. All other source, coverage, identity, negation, qualifier, local-card and unverified-proposal requirements remain unchanged.'''
CHECK_INSTRUCTIONS = INSTRUCTIONS + '\nNo independent paid checker is used.'


def bundle(records):
    source, table = v1.bundle(records)
    source.update(version=VERSION, coreColumns=['text', 'by', 'event'], organizationVocabulary=SYSTEMS)
    return source, table


def schema_for(records):
    schema = v6.schema_for(records)
    plan = v1.obj(owner=v1.S, followUp=v1.S, considerations=v1.S)
    def fact(categories, statuses, p):
        return v1.obj(k={'type': 'string', 'enum': categories}, s={'type': 'string', 'enum': statuses},
                      v={'type': 'array', 'items': v1.S, 'minItems': 3, 'maxItems': 3},
                      c={'type': 'array', 'items': v1.S, 'maxItems': 2}, p=p)
    schema['$defs']['fact'] = {'anyOf': [
        fact(['carePlan'], ACTION, plan), fact(['carePlan'], PAST, {'type': 'null'}),
        fact(['medications', 'symptoms', 'findings', 'contacts', 'other'], ACTION + PAST,
             {'anyOf': [{'type': 'null'}, plan]})]}
    condition = schema['properties']['conditions']['items']
    condition['properties'].pop('sections'); condition['required'].remove('sections')
    condition['properties']['systems']['items'] = {'type': 'string', 'enum': list(SYSTEMS)}
    return schema


def configure(records):
    global SCHEMA
    SCHEMA = schema_for(records)


def payload(records, proposal=None):
    if proposal is not None: raise ValueError('single_request_only')
    source, _ = bundle(records)
    p = {'stage': 'whole-history-generation', 'instructions': INSTRUCTIONS,
         'input': json.dumps(source, ensure_ascii=False, separators=(',', ':')),
         'response_format': {'type': 'json_schema', 'json_schema': {'name': 'passage_action_schema', 'strict': True, 'schema': schema_for(records)}}}
    upper = len(json.dumps(p, ensure_ascii=False).encode()) + 4096
    if upper + OUTPUT_TOKENS > CONTEXT_TOKENS: raise ValueError('context_limit_exceeded')
    return p, {'inputTokenUpperBound': upper, 'outputAllowance': OUTPUT_TOKENS, 'contextLimit': CONTEXT_TOKENS,
               'version': VERSION, 'documentation': 'https://developers.openai.com/api/docs/models/gpt-6-luna'}


def resolve(result, records):
    if not isinstance(result, dict) or set(result) != {'passages', 'conditions', 'relationships', 'overview'}:
        raise ValueError('malformed_object')
    typed = copy.deepcopy(result)
    if not isinstance(typed['passages'], dict): raise ValueError('malformed_passages')
    for pid, rows in typed['passages'].items():
        if isinstance(rows, str): continue
        if not isinstance(rows, list): raise ValueError('malformed_passage_rows')
        for row in rows:
            if not isinstance(row, dict) or set(row) != {'k', 's', 'v', 'c', 'p'} or not isinstance(row['v'], list) or len(row['v']) != 3:
                raise ValueError('invalid_fact_fields')
            category, status = row.pop('k'), row.pop('s')
            if category == 'carePlan' and ((status in ACTION and row['p'] is None) or (status in PAST and row['p'] is not None)):
                raise ValueError('action_metadata_contract')
            text, by, event = row['v']; row['v'] = [category, text, by, status, event]
    for condition in typed['conditions']:
        v1.validate_shape(condition, v1.obj(id=v1.S, name=v1.S, systems=v1.REFS, details=v1.REFS))
        if any(s not in SYSTEMS for s in condition['systems']): raise ValueError('unknown_app_body_system')
        words = set(__import__('re').findall(r'[a-z]+', condition['name'].lower()))
        sections = ['Pregnancy & related care' if s == 'reproductive' and words & {'pregnancy', 'pregnant'} else SYSTEMS[s] for s in condition['systems']]
        condition['sections'] = list(dict.fromkeys(sections))
    expanded, audit = v6.resolve(typed, records)
    audit.update(version=VERSION, organization='Actual app body-system vocabulary; navigation only, not evidence of a clinical relationship')
    return expanded, audit


def validate(result, records): return resolve(result, records)[1]
