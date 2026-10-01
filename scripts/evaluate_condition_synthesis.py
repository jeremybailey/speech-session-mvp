"""Compare condition organization on synthetic accepted histories. No patient records.
Default validates fixtures offline. Direct paid runs are disabled pending the budgeted production harness.
"""
import argparse, json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
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
    if args.run:
        parser.error('Direct paid evaluation is disabled: use the durable server ledger and shared $1 evaluation budget. No request sent.')
    for case in CASES:
        assert len({e['id'] for e in case['entries']})==len(case['entries'])
        assert assess(case,{'groups':[],'unassigned':[]}), 'Empty output must fail'
    if not args.run:
        print(f'Validated {len(CASES)} synthetic evaluation cases. No API requests made. Paid evaluation remains gated.')
        return

if __name__=='__main__': main()
