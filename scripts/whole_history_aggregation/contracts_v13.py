"""The completed compact-actions B contract, with only its overview condensed."""
import json
import contracts_v11 as previous
VERSION='compact-actions-short-overview-v1'
MODEL=previous.MODEL;OUTPUT_TOKENS=previous.OUTPUT_TOKENS;CONTEXT_TOKENS=previous.CONTEXT_TOKENS
install=previous.install
_old='overview: a brief synopsis in one to six paragraphs, each with text and supporting original passage IDs in cite.'
_new='overview: ONE concise patient-facing paragraph of roughly 100 words (aim for 80–120 words), with supporting original passage IDs in cite. No headings, sections, bullets, line breaks, or record-by-record catalogue. Prioritize the main health concerns and meaningful care priorities. Avoid repeating the detailed inventory; all underlying details, qualifiers and care actions must still be retained in passages. This condensed overview is produced in this same request; no separate summary call is used.'
assert _old in previous.INSTRUCTIONS
INSTRUCTIONS=previous.INSTRUCTIONS.replace(_old,_new)
CHECK_INSTRUCTIONS=INSTRUCTIONS+'\nNo independent paid checker is used.'

def bundle(records):
    data,table=previous.bundle(records);data['version']=VERSION;return data,table

def schema_for(records):
    schema=previous.schema_for(records);overview=schema['properties']['overview'];overview['minItems']=1;overview['maxItems']=1
    overview['items']['properties']['text'].update(maxLength=1000,pattern=r'^[^\r\n]+$')
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
    overview=result.get('overview') if isinstance(result,dict) else None
    if not isinstance(overview,list) or len(overview)!=1:raise ValueError('overview_must_be_one_paragraph')
    text=overview[0].get('text') if isinstance(overview[0],dict) else None
    if not isinstance(text,str) or not text.strip() or len(text)>1000 or '\n' in text or '\r' in text:raise ValueError('overview_not_condensed')
    out,audit=previous.resolve(result,records);audit['version']=VERSION
    return out,audit

def validate(result,records):return resolve(result,records)[1]
