"""Compare condition organization on synthetic accepted histories. No patient records.
Default validates fixtures offline. --run needs OPENAI_API_KEY and incurs API usage.
"""
import argparse, json, os, re, time, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT/'Sources/SpeechSessionPersistence/ConditionSynthesis.swift').read_text()
PROMPT = re.search(r'public static let instruction = """\n(.*?)\n    """',source,re.S).group(1)
CASES = json.loads((ROOT/'Tests/Fixtures/ConditionSynthesis/evaluation.json').read_text())

def assess(case, response):
    errors=[]
    ids=[e['id'] for e in case['entries']]
    groups=response.get('groups',[])
    assigned=[i for g in groups for i in g.get('entryIDs',[])]+response.get('unassigned',[])
    if len(assigned)!=len(ids) or set(assigned)!=set(ids): errors.append('incomplete, duplicate or invented IDs')
    owner={i:n for n,g in enumerate(groups) for i in g.get('entryIDs',[])}
    for indexes in case['together']:
        if any(ids[i] not in owner for i in indexes) or len({owner.get(ids[i]) for i in indexes})!=1: errors.append(f'related entries split: {indexes}')
    for a,b in case['apart']:
        if ids[a] in owner and owner.get(ids[a])==owner.get(ids[b]): errors.append(f'unrelated concerns merged: {a},{b}')
    for i in case['unassigned']:
        if ids[i] not in response.get('unassigned',[]): errors.append(f'non-condition promoted: {i}')
    for term in case['forbidden']:
        if any(term in g.get('name','').lower() for g in groups): errors.append(f'unsupported heading: {term}')
    for index,terms in case['required'].items():
        group=next((g for g in groups if ids[int(index)] in g.get('entryIDs',[])),{})
        if not all(term in group.get('name','').lower() for term in terms): errors.append('explicit condition name lost')
    if case['primary'] is not None:
        primary=[g for g in groups if g.get('isPrimary')]
        if len(primary)!=1 or ids[case['primary']] not in primary[0].get('entryIDs',[]): errors.append('patient priority lost')
    if 'eye' in case['name'] and any(g.get('bodySystem')!='eye' for g in groups): errors.append('ocular concern misclassified')
    return errors

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',action='store_true')
    parser.add_argument('--models',nargs='+',default=['gpt-4o-mini','gpt-6-luna','gpt-6-sol','gpt-6-astra'])
    parser.add_argument('--output',default='/tmp/condition-synthesis-evaluation.json')
    args=parser.parse_args()
    for case in CASES:
        assert len({e['id'] for e in case['entries']})==len(case['entries'])
        assert assess(case,{'groups':[],'unassigned':[]}), 'Empty output must fail'
    if not args.run:
        print(f'Validated {len(CASES)} synthetic evaluation cases. No API requests made. Use --run to compare models.')
        return
    key=os.environ.get('OPENAI_API_KEY')
    if not key: parser.error('OPENAI_API_KEY is required for --run; no request sent')
    results=[]
    for model in args.models:
        for case in CASES:
            payload={'model':model,'store':False,'max_output_tokens':16000,
                'input':[{'role':'system','content':PROMPT},{'role':'user','content':json.dumps({'entries':case['entries']})}],
                'text':{'format':{'type':'json_object'}}}
            if model.startswith('gpt-6-'): payload['reasoning']={'effort':'low'}
            started=time.monotonic()
            try:
                request=urllib.request.Request('https://api.openai.com/v1/responses',data=json.dumps(payload).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'})
                with urllib.request.urlopen(request,timeout=120) as response: raw=json.load(response)
                if raw.get('status')!='completed': raise ValueError('Incomplete response')
                text=next((part['text'] for item in raw.get('output',[]) if item.get('type')=='message'
                    for part in item.get('content',[]) if part.get('type')=='output_text'),None)
                if not text: raise ValueError('Missing structured output')
                result=json.loads(text)
                errors=assess(case,result)
                results.append(dict(model=model,case=case['name'],seconds=time.monotonic()-started,errors=errors,
                    response=result,usage=raw.get('usage'),request_id=raw.get('id')))
                print(model,case['name'],'PASS' if not errors else 'FAIL: '+ '; '.join(errors))
            except Exception as error:
                results.append(dict(model=model,case=case['name'],error=str(error)))
                print(model,case['name'],'REQUEST FAILED')
    Path(args.output).write_text(json.dumps(results,indent=2)+'\n')
    print('Results:',args.output)

if __name__=='__main__': main()
