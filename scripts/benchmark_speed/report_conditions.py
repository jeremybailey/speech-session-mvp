"""Private deterministic comparison of saved condition runs; no clinical auto-grading."""
import json
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('baseline',type=Path);p.add_argument('--candidate',default='controls-2');p.add_argument('--output-prefix',default='');a=p.parse_args()
r=a.root.resolve();base=a.baseline.resolve()
plan=json.loads((r/'frozen-plan.json').read_text());entries=sum(plan['batches'],[])
def load(run):
 report=json.loads((run/'run.json').read_text());assert report['completed'],'Incomplete runs are not speed comparisons'
 outputs=[]
 for f in (run/'trace').glob('*.receipt.json'):
  v=json.loads(f.read_text())
  if v.get('state')=='completed' and v.get('result',{}).get('output'):
   o=json.loads(v['result']['output'])
   if 'groups' in o:outputs.append(o)
 assert len(outputs)==1
 result=outputs[0];ids=[i for g in result['groups'] for i in g['entryIDs']]+result['unassigned']
 assert len(ids)==len(set(ids)) and set(ids)=={e['id'] for e in entries}
 ledger=json.loads((run/'ledger.json').read_text());manifest=json.loads((run.parent/'manifest.json').read_text());owner=manifest['ownerPrefix']+run.name
 jobs=[j for j in ledger['jobs'] if j['owner']==owner]
 phases={x['phase']:x['seconds'] for x in report['phases']}
 stats={'seconds':phases['conditions'],'requests':len(jobs),'costUSD':sum(int(j['cost_nusd'] if j['cost_nusd'] is not None else j['reserve_nusd']) for j in jobs)/1e9,
  'outputTokens':sum(int(j.get('output_tokens') or 0) for j in jobs),'inputTokens':sum(int(j.get('input_tokens') or 0) for j in jobs),
  'providerSeconds':sum(j.get('provider_seconds') or 0 for j in jobs),'failures':sum(j['state']!='completed' for j in jobs),
  'groups':len(result['groups']),'unassigned':len(result['unassigned']),'occurrences':len(ids)}
 stats['stages']={stage:{'requests':sum(j['stage']==stage for j in jobs),
   'providerSeconds':sum(j.get('provider_seconds') or 0 for j in jobs if j['stage']==stage),
   'reasoningEfforts':sorted({j.get('reasoning_effort') or 'unreported' for j in jobs if j['stage']==stage})}
   for stage in sorted({j['stage'] for j in jobs})}
 return stats,result
b,br=load(base);c,cr=load(r/a.candidate)
def assignments(result):return {i:{'name':g['name'],'bodySystem':g['bodySystem']} for g in result['groups'] for i in g['entryIDs']}
bm,cm=assignments(br),assignments(cr)
changes=[{'entryID':e['id'],'title':e.get('title'),'baseline':bm.get(e['id']),'candidate':cm.get(e['id'])} for e in entries if bm.get(e['id'])!=cm.get(e['id'])]
report={'baseline':b,'candidate':c,'ratio':c['seconds']/b['seconds'],'speedup':b['seconds']/c['seconds'],
 'sourceOccurrencesPreserved':True,'assignmentChanges':changes,'clinicalAccuracy':'Pending semantic review; name changes alone are not failures.'}
(r/(a.output_prefix+'comparison.json')).write_text(json.dumps(report,indent=2))
(r/(a.output_prefix+'candidate-synthesis.json')).write_text(json.dumps(cr,indent=2));(r/(a.output_prefix+'baseline-synthesis.json')).write_text(json.dumps(br,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='assignmentChanges'},indent=2));print('Assignment changes:',len(changes))
