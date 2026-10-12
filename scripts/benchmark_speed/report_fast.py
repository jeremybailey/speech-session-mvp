"""Report completed cold timings separately from recovery, with auditable accounting."""
import argparse,json,collections
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('historical',type=Path);a=p.parse_args()
old=json.loads(a.historical.read_text());baseline=old.get('elapsedSeconds') or sum(x['seconds'] for x in old['phases'] if x['phase'].startswith('record:'))
rows=[]
for path in sorted(a.root.glob('*/run.json')):
 d=json.loads(path.read_text()); trace=path.parent/'trace'; counts=collections.Counter(); receipts={}; phases={}
 for f in trace.glob('*.request.json'):
  request=json.loads(f.read_text()); counts[request.get('diagnostic_phase',request.get('stage','unknown'))]+=1
 for f in trace.glob('*.receipt.json'):
  receipt=json.loads(f.read_text())
  if 'id' in receipt:
   receipts[receipt['id']]=receipt
   request=json.loads(f.with_name(f.name.replace('.receipt','.request')).read_text())
   phases[receipt['id']]=request.get('diagnostic_phase',request.get('stage','unknown'))
 ledger=json.loads((path.parent/'ledger.json').read_text()) if (path.parent/'ledger.json').exists() else {'jobs':[]}
 jobs=[j for j in ledger['jobs'] if j['id'] in receipts]
 provider=collections.defaultdict(float); costs=collections.defaultdict(float)
 for j in jobs:
  phase=phases.get(j['id'],j['stage'])
  provider[phase]+=j.get('provider_seconds') or 0
  costs[phase]+=int(j.get('cost_nusd') or 0)/1e9
 store=json.loads((path.parent/'store/sessions.json').read_text())
 split_count=sum(key.endswith('/split') for session in store['sessions'] for key in (session.get('summaryRun') or {}).get('workUnits',{}))
 retries=[json.loads(f.read_text()) for f in sorted(path.parent.glob('resume-*.json'))]
 comparable=d.get('completed') and d.get('cold') and d.get('records')==5
 rows.append({'run':d['run'],'completed':d['completed'],'cold':d['cold'],'records':d['records'],'seconds':d['elapsedSeconds'],
  'schedulerMetrics':d.get('schedulerMetrics'), 'recoveryAttempts':retries,
  'requestAttemptsAcrossColdAndRecovery':dict(counts),'uniquePaidJobsAcrossColdAndRecovery':len(jobs),
  'jobStates':dict(collections.Counter(j['state'] for j in jobs)),
  'inputTokens':sum(int(j.get('input_tokens') or 0) for j in jobs),
  'outputTokens':sum(int(j.get('output_tokens') or 0) for j in jobs), 'splitBatchCount':split_count,
  'providerSecondsByStageAcrossColdAndRecovery':dict(provider),'actualCostUSDByStageAcrossColdAndRecovery':dict(costs),
  'unresolvedReservationsUSD':sum(int(j['reserve_nusd']) for j in jobs if j.get('cost_nusd') is None)/1e9,
  'historicalDetailsRatio':d['elapsedSeconds']/baseline if comparable else None,
  'accuracy':'Ungraded; no equivalence claim. Condition dimensions not measured in this details-only run.'})
report={'historicalDetailsSeconds':baseline,'comparisonLimitation':'Historical completed concurrent run, not a fresh paired serial baseline. Same frozen sources/key. Provider durations overlap; they are not wall-clock stage durations.', 'runs':rows}
(a.root/'fast-comparison.json').write_text(json.dumps(report,indent=2))
lines=['# Fast health details experiment','',f'Historical completed details time: {baseline:.1f} seconds. This is context, not a fresh paired baseline.','',
 '| Run | Completed cold | Records | Cold seconds | Ratio to historical details |','|---|---|---:|---:|---:|']
for r in rows:
 lines.append(f"| {r['run']} | {r['completed']} | {r['records']} | {r['seconds']:.1f} | {r['historicalDetailsRatio']} |")
for r in rows:
 lines += ['',f"## {r['run']}",f"Unique jobs including retries: {r['uniquePaidJobsAcrossColdAndRecovery']}; settled cost: ${sum(r['actualCostUSDByStageAcrossColdAndRecovery'].values()):.6f}; unresolved reservations: ${r['unresolvedReservationsUSD']:.6f}.",f"Job states: {r['jobStates']}.",f"Provider seconds by stage (overlapping): {r['providerSecondsByStageAcrossColdAndRecovery']}."]
 for retry in r['recoveryAttempts']:lines.append(f"Checkpoint retry: completed={retry['completed']}, {retry['elapsedSeconds']:.1f} seconds. Excluded from cold speed comparisons.")
lines+=['','Accuracy remains ungraded until semantic per-row review. No condition-link scores are inferred from a details-only run.']
(a.root/'FastReport.md').write_text('\n'.join(lines)+'\n');print(json.dumps(report,indent=2))
