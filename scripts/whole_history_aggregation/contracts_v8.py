"""Full current-app category policy, with source/owner validation unchanged."""
import copy
import json
import contracts as v1
import contracts_v7 as v7

VERSION = 'passage-full-app-categories-v1'
MODEL = v1.MODEL
OUTPUT_TOKENS = v1.OUTPUT_TOKENS
CONTEXT_TOKENS = v1.CONTEXT_TOKENS
SCHEMA = None
CATEGORIES = {
    'chiefComplaint': 'Explicit primary reason for seeking care in this encounter; not every symptom or test indication.',
    'symptoms': 'Patient-reported sensations, difficulties and functional problems, including mental-health symptoms. Preserve attribution; do not promote to diagnosis.',
    'findings': 'Explicit patient-specific diagnoses, examination findings and clinical impressions, preserving uncertainty; not raw lab/imaging results or suspected conditions being ruled out.',
    'medications': 'Named medicines/supplements, prescriptions and dispensing history. Strength/dose/frequency/pharmacy are attributes. Proposed medication changes as instructions belong in carePlan.',
    'carePlan': 'Treatment, clinician-directed actions, referrals, orders, education, lifestyle recommendations and home exercises. Preserve planned versus received; do not invent instructions.',
    'practitionerContact': 'Named practitioner, organization or care contact; contact details are attributes. Mention of a practitioner in another fact does not turn that fact into a contact. A patient named on a label is not a provider.',
    'vaccinations': 'Vaccine history/events; distinguish prescribed, dispensed, planned and administered. Prescription does not prove administration.',
    'allergies': 'Explicit allergies, intolerances or adverse reactions, including negative allergy history; not unrelated symptoms or speculative side effects.',
    'testsAndLabs': 'Reported lab, imaging and diagnostic-test results, including normal values, units and ranges. Future test orders as actions belong in carePlan.',
    'followUp': 'Return timing, appointments, booking and callback logistics. Therapeutic instructions belong in carePlan.',
    'biopsychosocialContext': 'Explicit life circumstances: work, housing, relationships, support, caregiving, significant events, diet, sleep habits, substances, coping and psychological context. Symptoms are symptoms; diagnoses are findings; clinician-directed changes are carePlan. Do not infer causation.',
    'otherNotes': 'Relevant health information genuinely fitting none of the above; not metadata, disclaimers or uncertain classification.'}
INSTRUCTIONS = v7.INSTRUCTIONS + '''

FULL APP CATEGORIES (authoritative): The input includes appCategoryPolicy, the actual current app category definitions. Use exactly those twelve k codes. The earlier generic contacts and other aliases are NOT output categories. In particular, explicit intolerances/allergies, lab values, vaccine events and follow-up logistics have their own categories. Use them by source meaning, not keywords, and never drop a fact because it lacks complete metadata. Preserve provider/patient distinctions and medication prescribed-versus-taken-versus-proposed status. A label's pharmacy is a care contact and its patient name is not a provider.

For future/conditional carePlan AND followUp actions, p is required as an object with known actor/timing/considerations; absent values stay empty. Historical/performed/observed/resolved carePlan/followUp items use p=null. Medication directions may have p in prescribed/recommended/conditional/planned status. All other categories use p=null: do not turn a lab result, symptom, contact name, allergy or life circumstance into a future task. The same category policy applies across every original, including duplicate records. No answer-key label or expected patient fact is provided. Retain independently supported clinical concerns and source uncertainty; navigation buckets do not replace distinct conditions.'''
CHECK_INSTRUCTIONS = INSTRUCTIONS + '\nNo independent paid checker is used.'


def bundle(records):
    source, table = v7.bundle(records)
    source.update(version=VERSION, appCategoryPolicy=CATEGORIES)
    return source, table


def schema_for(records):
    schema = v7.schema_for(records)
    branches = schema['$defs']['fact']['anyOf']
    branches[0]['properties']['k']['enum'] = ['carePlan', 'followUp']
    branches[1]['properties']['k']['enum'] = ['carePlan', 'followUp']
    branches[2]['properties']['k']['enum'] = [k for k in CATEGORIES if k not in ('carePlan', 'followUp')]
    return schema


def configure(records):
    global SCHEMA
    SCHEMA = schema_for(records)


def payload(records, proposal=None):
    if proposal is not None: raise ValueError('single_request_only')
    source, _ = bundle(records)
    p = {'stage': 'whole-history-generation', 'instructions': INSTRUCTIONS,
         'input': json.dumps(source, ensure_ascii=False, separators=(',', ':')),
         'response_format': {'type': 'json_schema', 'json_schema': {'name': 'full_app_category_facts', 'strict': True, 'schema': schema_for(records)}}}
    upper = len(json.dumps(p, ensure_ascii=False).encode()) + 4096
    if upper + OUTPUT_TOKENS > CONTEXT_TOKENS: raise ValueError('context_limit_exceeded')
    return p, {'inputTokenUpperBound': upper, 'outputAllowance': OUTPUT_TOKENS, 'contextLimit': CONTEXT_TOKENS,
               'version': VERSION, 'documentation': 'https://developers.openai.com/api/docs/models/gpt-6-luna'}


def resolve(result, records):
    if not isinstance(result, dict) or set(result) != {'passages', 'conditions', 'relationships', 'overview'}: raise ValueError('malformed_object')
    typed = copy.deepcopy(result)
    originals = {}
    if not isinstance(typed['passages'], dict): raise ValueError('malformed_passages')
    aliases = {'practitionerContact': 'contacts', 'otherNotes': 'other', 'followUp': 'carePlan'}
    for pid, rows in typed['passages'].items():
        if isinstance(rows, str): continue
        if not isinstance(rows, list): raise ValueError('malformed_passage_rows')
        for n, row in enumerate(rows, 1):
            if not isinstance(row, dict) or set(row) != {'k', 's', 'v', 'c', 'p'} or row['k'] not in CATEGORIES: raise ValueError('unknown_app_category')
            original = row['k']; originals[f'{pid}.{n}'] = original
            if row['p'] is not None and original not in ('carePlan', 'followUp', 'medications'): raise ValueError('non_action_plan_metadata')
            # Only a compatibility adapter for the unchanged identity resolver;
            # restore the actual declared app category without changing claims.
            row['k'] = aliases.get(original, original if original in ('carePlan', 'medications', 'symptoms', 'findings') else 'other')
    expanded, audit = v7.resolve(typed, records)
    for detail in expanded['details']: detail['category'] = originals[detail['id']]
    audit.update(version=VERSION, appCategories=list(CATEGORIES), categoryProjection='Original declared app categories preserved; no semantic relabelling')
    return expanded, audit


def validate(result, records): return resolve(result, records)[1]
