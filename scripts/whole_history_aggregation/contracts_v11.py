"""Paired lossless passages and compact action metadata; unchanged clinical gates."""
import copy
import json
import contracts as source
import contracts_v10 as previous
VERSION='paired-source-compact-actions-v1'
MODEL=previous.MODEL; OUTPUT_TOKENS=previous.OUTPUT_TOKENS; CONTEXT_TOKENS=previous.CONTEXT_TOKENS
_original_bundle=source.bundle

def paired_bundle(records):
    result,old=_original_bundle(records);table={}
    for record in result['originalRecords']:
        chunks=record['passages'];paired=[]
        for n in range(0,len(chunks),2):
            group=chunks[n:n+2];pid=f"{record['r']}.p{len(paired)+1}"
            first=old[group[0]['id']];last=old[group[-1]['id']]
            quote=''.join(x['text'] for x in group)
            paired.append({'id':pid,'text':quote})
            table[pid]={**first,'end':last['end'],'quote':quote}
        record['passages']=paired
    result['version']=VERSION
    return result,table

def install():source.bundle=paired_bundle

def bundle(records):
    data,table=previous.bundle(records);data['version']=VERSION;return data,table

INSTRUCTIONS=previous.INSTRUCTIONS.replace('Historical/performed/observed/resolved actions have p=null and must not become future tasks.','All carePlan/followUp actions, including past/performed care, require plan metadata and source-time status.')
INSTRUCTIONS+='''\nCOMPACT ACTION METADATA: p uses a for responsible actor, t for follow-up timing, q for considerations (replacing owner/followUp/considerations). Preserve the same information. Each passage is a larger lossless source span; extract distinct facts within it without paraphrase duplicates. Do not repeat the same clinical assertion within the same original merely because a speaker repeats it; cite additional context where needed. Preserve distinct occurrences across different originals. This never permits dropping differing qualifiers, changes, actors or actions. All care-state rules above still apply.'''

CHECK_INSTRUCTIONS=INSTRUCTIONS+'\nNo independent paid checker is used.'

def schema_for(records):
    schema=previous.schema_for(records)
    for branch in schema['$defs']['fact']['anyOf']:
        p=branch['properties']['p'];plans=p.get('anyOf',[p])
        for plan in plans:
            if plan.get('type')=='object' and 'owner' in plan['properties']:
                plan['properties']={dict(owner='a',followUp='t',considerations='q')[k]:v for k,v in plan['properties'].items()}
                plan['required']=['a','t','q']
    return schema

def configure(records):
    global SCHEMA
    SCHEMA=schema_for(records)

def payload(records,proposal=None):
    if proposal is not None:raise ValueError('single_request_only')
    data,_=bundle(records)
    p={'stage':'whole-history-generation','instructions':INSTRUCTIONS,'input':json.dumps(data,ensure_ascii=False,separators=(',',':')),'response_format':{'type':'json_schema','json_schema':{'name':'paired_source_compact_actions','strict':True,'schema':schema_for(records)}}}
    upper=len(json.dumps(p,ensure_ascii=False).encode())+4096
    if upper+OUTPUT_TOKENS>CONTEXT_TOKENS:raise ValueError('context_limit_exceeded')
    return p,{'inputTokenUpperBound':upper,'outputAllowance':OUTPUT_TOKENS,'contextLimit':CONTEXT_TOKENS,'version':VERSION}

def resolve(result,records):
    typed=copy.deepcopy(result)
    for rows in typed['passages'].values():
        if isinstance(rows,str):continue
        for row in rows:
            if row['p'] is not None:
                if set(row['p'])!={'a','t','q'}:raise ValueError('invalid_compact_plan')
                row['p']={dict(a='owner',t='followUp',q='considerations')[k]:v for k,v in row['p'].items()}
    out,audit=previous.resolve(typed,records);audit['version']=VERSION
    return out,audit

def validate(result,records):return resolve(result,records)[1]
