"""Care-action states refer to source evidence, not record age or schema shortcuts."""
import copy
import json
import re
import contracts as source_contract
import contracts_v9 as previous

VERSION='source-time-action-states-v1'
MODEL=previous.MODEL;OUTPUT_TOKENS=previous.OUTPUT_TOKENS;CONTEXT_TOKENS=previous.CONTEXT_TOKENS
SCHEMA=None
CARE_STATUSES=['recommended','conditional','planned','prescribed','declined','performed','historical','reported','unclear']
INSTRUCTIONS=previous.INSTRUCTIONS+'''

CARE-STATE PRIORITY: A recommendation being documented in an older record does NOT mean the recommendation was completed, withdrawn or resolved. Status is the assertion's state AT THE DOCUMENTED ENCOUNTER. An instruction offered then remains recommended/planned/conditional unless source explicitly says it was carried out or had already become past care. Use historical only for care explicitly described as prior/past relative to that encounter, such as a patient's earlier treatment attempts. Use performed only for an intervention actually provided. Do NOT label advice or possible options performed/historical merely because the clinician discussed them in the past. Care actions cannot use resolved or observed: those are not evidence that the patient completed a plan.

Every carePlan and followUp fact now requires a p object, including past/performed care. Supply the responsible actor and timing when established; otherwise empty strings. The application retains historical/performed cards with their source status and never converts them into future tasks. Distinguish the source speaker from the responsible actor. For past treatment where the practitioner/actor is unnamed, do not guess a clinician or assume the patient performed the treatment on themself. Medication-use history still has p=null; a medication direction can carry its explicit plan metadata.

If one passage mixes medication history with a clinician's start/stop/continue instruction, return separate facts with the correct categories/states. Likewise separate a reported finding from advice to monitor/treat it. Preserve conditional antibiotic discussions as CONDITIONAL, not completed care; no hypothetical prescription proves use. Do not suppress an instruction just because treatment was not yet arranged.

Keep text concise per atomic fact. Avoid repeating an attribution introduction when the by field already captures it, EXCEPT when embedded attribution is necessary to preserve a patient's report of someone else's view. Never omit uncertainty, negation, numeric/medication qualifiers, ownership or timing to shorten output. All other original-only, source-identity, app-category, concern-planning and unverified-proposal requirements remain unchanged.'''
CHECK_INSTRUCTIONS=INSTRUCTIONS+'\nNo independent paid checker is used.'


def bundle(records):
    source,table=previous.bundle(records);source['version']=VERSION;return source,table


def schema_for(records):
    schema=previous.schema_for(records);S=source_contract.S;obj=source_contract.obj
    src={'$ref':'#/$defs/sourceRef'};concern={'$ref':'#/$defs/concernRef'}
    def fact(kinds,statuses,p):
        return obj(k={'type':'string','enum':kinds},s={'type':'string','enum':statuses},
                   v={'type':'array','items':S,'minItems':3,'maxItems':3},c={'type':'array','items':src,'maxItems':2},
                   p=p,g={'type':'array','items':concern})
    plan=obj(owner=S,followUp=S,considerations=S)
    schema['$defs']['fact']={'anyOf':[
        fact(['carePlan','followUp'],CARE_STATUSES,plan),
        fact([k for k in previous.CATEGORIES if k not in ('carePlan','followUp')],previous.STATUSES,{'anyOf':[{'type':'null'},plan]})]}
    return schema


def configure(records):
    global SCHEMA
    SCHEMA=schema_for(records)


def payload(records,proposal=None):
    if proposal is not None:raise ValueError('single_request_only')
    source,_=bundle(records)
    p={'stage':'whole-history-generation','instructions':INSTRUCTIONS,'input':json.dumps(source,ensure_ascii=False,separators=(',',':')),
       'response_format':{'type':'json_schema','json_schema':{'name':'source_time_action_states','strict':True,'schema':schema_for(records)}}}
    upper=len(json.dumps(p,ensure_ascii=False).encode())+4096
    if upper+OUTPUT_TOKENS>CONTEXT_TOKENS:raise ValueError('context_limit_exceeded')
    return p,{'inputTokenUpperBound':upper,'outputAllowance':OUTPUT_TOKENS,'contextLimit':CONTEXT_TOKENS,'version':VERSION,
              'documentation':'https://developers.openai.com/api/docs/models/gpt-6-luna'}


def resolve(result,records):
    if not isinstance(result,dict) or not isinstance(result.get('passages'),dict):raise ValueError('malformed_object')
    typed=copy.deepcopy(result);past=[];original={};category_adjustments={};restore_categories={}
    for pid,rows in typed['passages'].items():
        if isinstance(rows,str):continue
        if not isinstance(rows,list):raise ValueError('malformed_passage_rows')
        for n,row in enumerate(rows,1):
            if not isinstance(row,dict) or set(row)!={'k','s','v','c','p','g'}:raise ValueError('invalid_fact_fields')
            fid=f'{pid}.{n}';original[fid]=copy.deepcopy(row)
            # Current app category boundaries: a planned test order is an
            # action, while a reported result remains a test result. Callback
            # logistics are followUp, rather than a provider-contact entry.
            # Typed intent/actor/time and all clinical words stay unchanged.
            if row['p'] is not None and row['s'] in ('planned','recommended','conditional','prescribed'):
                if row['k']=='testsAndLabs':
                    category_adjustments[fid]={'from':'testsAndLabs','to':'carePlan','rule':'future test order with explicit plan metadata'};row['k']='carePlan'
                elif row['k']=='practitionerContact':
                    category_adjustments[fid]={'from':'practitionerContact','to':'followUp','rule':'planned callback/appointment with explicit plan metadata'};row['k']='followUp'
                elif row['k']=='vaccinations':
                    restore_categories[fid]='vaccinations';row['k']='carePlan'
            if row['k'] in ('carePlan','followUp'):
                if row['s'] not in CARE_STATUSES or row['p'] is None:raise ValueError('invalid_care_state_or_missing_metadata')
                source_contract.validate_shape(row['p'],source_contract.obj(owner=source_contract.S,followUp=source_contract.S,considerations=source_contract.S))
                if re.fullmatch(r'r\d+\.p\d+(?:\.\d+)?',row['p']['owner']):raise ValueError('source_locator_is_not_plan_owner')
                if row['s'] in ('historical','performed'):
                    past.append((fid,copy.deepcopy(row['p'])));row['p']=None
    expanded,audit=previous.resolve(typed,records)
    by_id={d['id']:d for d in expanded['details']}
    for fid,category in restore_categories.items():by_id[fid]['category']=category
    for card in expanded['carePlans']:
        fid=card['occurrenceIDs'][0];card['sourceStatus']=original[fid]['s'];card['sourceEvent']=original[fid]['v'][2]
    for fid,plan in past:
        d=by_id[fid]
        expanded['carePlans'].append({'id':'past-plan:'+fid,'title':d['title'],'owner':plan['owner'],'action':d['title'],
          'followUp':plan['followUp'],'considerations':plan['considerations'],'occurrenceIDs':[fid],
          'conditionIDs':d['conditionIDs'],'sources':d['sources'],'sourceStatus':d['clinicalStatus'],'sourceEvent':d['date']})
    audit.update(version=VERSION,localCareCardCount=len(expanded['carePlans']),pastCareCards=len(past),categoryAdjustments=category_adjustments,
                 careStateMeaning='Source-encounter state only; no completion, withdrawal or resolution inferred from record age')
    return expanded,audit


def validate(result,records):return resolve(result,records)[1]
