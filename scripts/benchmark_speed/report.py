"""Summarize measured timing/accounting; fail closed on absent accuracy or repeated runs."""
import argparse,hashlib,json,statistics
from datetime import datetime
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from compare_scorecards import compare

def summary(root):
 arms={};runs=[]
 manifest=json.loads((root/'manifest.json').read_text()) if (root/'manifest.json').exists() else {}
 ledgerPaths=[root/'status-cleanup.json']+sorted(root.glob('*-[1-3]/ledger.json'),key=lambda p:p.stat().st_mtime,reverse=True)
 ledger=next((json.loads(p.read_text()) for p in ledgerPaths if p.exists()),{})
 for f in sorted(root.glob('*-[1-3]/run.json')):
  r=json.loads(f.read_text());trace=f.parent/'trace'
  seedPath=root/'seed.json';storePath=f.parent/'store/sessions.json'
  r['sourceTranscriptsPreserved']=None
  if seedPath.exists() and storePath.exists():
   sourceMap=lambda path:{s['id']:s['transcript'] for s in json.loads(path.read_text())['sessions']}
   r['sourceTranscriptsPreserved']=sourceMap(seedPath)==sourceMap(storePath)
  hybrid=[json.loads(p.read_text()) for p in trace.glob('*.hybrid.json')]
  timing=[json.loads(p.read_text()) for p in trace.glob('*.timing.json')]
  r['checkingSecondsSum']=sum(t['elapsedSeconds'] for t in timing if t['stage']=='checking')
  stages={}
  for t in timing:
   stage=stages.setdefault(t['stage'],{'requests':0,'sumElapsedSeconds':0})
   stage['requests']+=1;stage['sumElapsedSeconds']+=t['elapsedSeconds']
  r['stages']=stages
  substages={}
  for requestPath in trace.glob('*.request.json'):
   payload=json.loads(requestPath.read_text())
   if payload.get('stage')!='checking':continue
   try:input=json.loads(payload['input'])
   except (ValueError,KeyError):continue
   label='citation-repair' if 'missingCitationFields' in input else 'initial-or-type-check'
   row=substages.setdefault(label,{'requests':0,'completedSeconds':0});row['requests']+=1
   timingPath=requestPath.with_name(requestPath.name.replace('.request.json','.timing.json'))
   if timingPath.exists():row['completedSeconds']+=json.loads(timingPath.read_text())['elapsedSeconds']
  r['checkingSubstages']=substages
  receipts={}
  for p in trace.glob('*.receipt.json'):
   job=json.loads(p.read_text())
   if job.get('id'):receipts[job['id']]=job
  r['knownCostUSD']=sum(int(j.get('cost_nusd') or 0) for j in receipts.values())/1e9
  jobs=[j for j in ledger.get('jobs',[]) if j['owner']==manifest.get('ownerPrefix',manifest.get('prefix',''))+r['run']]
  if jobs:
   r['ledgerCostUSD']=sum(int(j.get('cost_nusd') or 0) for j in jobs)/1e9
   r['unresolvedReservationUSD']=sum(int(j['reserve_nusd']) for j in jobs if j.get('cost_nusd') is None)/1e9
   r['ledgerRequestCount']=len(jobs)
   r['completionFailures']=[{k:j.get(k) for k in ['id','stage','state','input_tokens','output_tokens']} for j in jobs if j['state'] not in ['completed','queued','running']]
  r['providerSecondsRecorded']=sum((j.get('result') or {}).get('providerSeconds',0) for j in receipts.values())
  r['providerTimedRequests']=sum('providerSeconds' in (j.get('result') or {}) for j in receipts.values())
  r['queueWaitSeconds']=sum((datetime.fromisoformat(j['started_at'].replace('Z','+00:00'))-datetime.fromisoformat(j['created_at'].replace('Z','+00:00'))).total_seconds() for j in receipts.values() if j.get('created_at') and j.get('started_at'))
  if jobs:
   r['queueWaitSeconds']=sum((datetime.fromisoformat(j['started_at'].replace('Z','+00:00'))-datetime.fromisoformat(j['created_at'].replace('Z','+00:00'))).total_seconds() for j in jobs if j.get('created_at') and j.get('started_at'))
   if any(j.get('provider_seconds') is not None for j in jobs):
    r['providerSecondsRecorded']=sum(j.get('provider_seconds') or 0 for j in jobs)
    r['providerTimedRequests']=sum(j.get('provider_seconds') is not None for j in jobs)
  r['hybrid']={k:sum(h[k] for h in hybrid) for k in ['entries','eligible','accepted','fallback']}
  r['requestCount']=len(list(trace.glob('*.request.json')));r['transportCalls']=len(list(trace.glob('*.transport.json')))
  r['transportFailures']=[]
  for response in list(trace.glob('*.receive.json'))+list(trace.glob('*.transport-response.json')):
   try: body=json.loads(response.read_text())
   except (ValueError,UnicodeError): continue
   error=body.get('error') if isinstance(body,dict) else None
   if isinstance(error,dict) and str(error.get('code')) in ('401','403') and isinstance(body.get('protection'),dict):
    r['transportFailures'].append({'kind':'deployment_authentication','httpStatus':str(error['code'])})
  # Earlier harness runs incorrectly reported vacuous preservation on early failure.
  if r.get('originalOccurrenceCount')==0:r['sourceOccurrencesPreserved']=None
  r['accuracyReports']=[]
  for sf in f.parent.glob('*.score.json'):r['accuracyReports'].append(json.loads(sf.read_text()))
  runs.append(r)
  if r['completed'] and r.get('cold') is True:arms.setdefault(r['run'].rsplit('-',1)[0],[]).append(r['elapsedSeconds'])
 medians={a:statistics.median(t) for a,t in arms.items()}
 ratio={a:t/medians['baseline'] for a,t in medians.items() if a!='baseline' and 'baseline' in medians}
 # The acceptance audit is deliberately separate from timing; aggregate scores alone cannot clear regressions.
 gates=root/'accuracy-review.json';review=json.loads(gates.read_text()) if gates.exists() else None
 eligible=[];comparisons=[]
 keyHash=hashlib.sha256((root/'key.json').read_bytes()).hexdigest() if (root/'key.json').exists() else None
 for arm,rt in ratio.items():
  complete=[r for r in runs if r['completed'] and r.get('cold') is True and r['run'].startswith(arm+'-')]
  baselines={r['run'].rsplit('-',1)[1]:r for r in runs if r['completed'] and r.get('cold') is True and r['run'].startswith('baseline-')}
  accuracyOK=True
  for candidate in complete:
   baseline=baselines.get(candidate['run'].rsplit('-',1)[1]);old={s['recordID']:s for s in baseline['accuracyReports']} if baseline else {};new={s['recordID']:s for s in candidate['accuracyReports']}
   if len(old)!=5 or old.keys()!=new.keys() or not keyHash:accuracyOK=False;continue
   for rid,score in new.items():
    try:
     if score['keySHA256']!=keyHash:raise ValueError('Key changed')
     for run,report in [(candidate,score),(baseline,old[rid])]:
      path=root/run['run']/(rid+'.output.json')
      if report.get('outputSHA256')!=hashlib.sha256(path.read_bytes()).hexdigest():raise ValueError('Output changed')
     delta=compare(old[rid],score);comparisons.append(dict(arm=arm,run=candidate['run'],**delta))
     if delta['regressions'] or score['score']['passed']<old[rid]['score']['passed']:accuracyOK=False
     for dimension,before in old[rid]['dimensions'].items():
      after=score['dimensions'].get(dimension,{})
      if after.get('scored')!=before['scored'] or after.get('passed',-1)<before['passed']:accuracyOK=False
    except (ValueError,KeyError,OSError):accuracyOK=False
  if len(arms.get('baseline',[]))>=3 and len(arms[arm])>=3 and rt<=.5 and accuracyOK and all(r.get('sourceOccurrencesPreserved') is True and r.get('sourceTranscriptsPreserved') is True for r in complete) and review and review.get(arm,{}).get('approved') is True:eligible.append(arm)
 shadowPath=root/'shadow/comparison.json';shadow=json.loads(shadowPath.read_text()) if shadowPath.exists() else {}
 verdicts=[r for r in shadow.get('rows',[]) if 'agrees' in r]
 experimentJobs=ledger.get('jobs',[])
 return {'runs':runs,'rowComparisons':comparisons,'completedMediansSeconds':medians,'timeRatioToBaseline':ratio,'releaseEligibleArms':eligible,'accuracyReviewAvailable':review is not None,'experimentAccounting':{'settledUSD':sum(int(j.get('cost_nusd') or 0) for j in experimentJobs)/1e9,'unresolvedReservationUSD':sum(int(j['reserve_nusd']) for j in experimentJobs if j.get('cost_nusd') is None)/1e9,'ledgerAvailable':bool(ledger)},'shadow':{'judgments':len(verdicts),'agreements':sum(r['agrees'] for r in verdicts),'disagreements':[r for r in verdicts if not r['agrees']]},'limitations':['Diagnostic transport overhead is included; this is not an on-device wall-clock measurement.','Stage sums can overlap under concurrency; total elapsed is measured independently.','Incomplete runs never count as successful timings.','No candidate qualifies without repeated complete runs and explicit per-row accuracy review.']}
def main():
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);a=p.parse_args();d=summary(a.root)
 (a.root/'comparison.json').write_text(json.dumps(d,indent=2))
 lines=['# Reprocessing speed experiment','', '| Run | Completed | Elapsed seconds | Model requests | Settled USD | Hybrid accepted / eligible |','|---|---|---:|---:|---:|---:|']
 for r in d['runs']:lines.append(f"| {r['run']} | {r['completed']} | {r['elapsedSeconds']:.1f} | {r.get('ledgerRequestCount',r['requestCount'])} | {r.get('ledgerCostUSD',r['knownCostUSD']):.6f} | {r['hybrid']['accepted']} / {r['hybrid']['eligible']} |")
 lines+=['','Completed full-run medians: '+(json.dumps(d['completedMediansSeconds']) if d['completedMediansSeconds'] else 'unavailable; no completed runs'),'',f"Experiment settled cost: ${d['experimentAccounting']['settledUSD']:.6f}; unresolved reservations: ${d['experimentAccounting']['unresolvedReservationUSD']:.6f} (ledger available: {d['experimentAccounting']['ledgerAvailable']}).",'',f"Decisions shadow agreement: {d['shadow']['agreements']}/{d['shadow']['judgments']}; this is not accuracy against the human key."]
 for r in d['runs']:
  lines+=['',f"## {r['run']}",'','| Stage | Completed requests | Sum elapsed seconds |','|---|---:|---:|']
  for stage,v in r['stages'].items():lines.append(f"| {stage} | {v['requests']} | {v['sumElapsedSeconds']:.1f} |")
  lines+=['','| Full-pipeline phase | Completed | Elapsed seconds |','|---|---|---:|']
  for phase in r.get('phases',[]):lines.append(f"| {phase['phase']} | {phase['completed']} | {phase['seconds']:.1f} |")
  lines+=['',f"Queue wait: {r['queueWaitSeconds']:.1f}s; provider time: {r['providerSecondsRecorded']:.1f}s across {r['providerTimedRequests']} instrumented requests. Missing measurements are not zero.",f"Run failure: {r.get('failure') or 'none'}. Provider failures: {json.dumps(r.get('completionFailures',[]))}. Transport failures: {json.dumps(r.get('transportFailures',[]))}",f"Original transcripts preserved: {r.get('sourceTranscriptsPreserved')}; generated source occurrences preserved: {r.get('sourceOccurrencesPreserved')}.",f"Row/dimension score reports: {len(r['accuracyReports'])}. No ungraded row is counted as a pass."]
 lines+=['','Release-qualified candidates: '+(', '.join(d['releaseEligibleArms']) or 'none established'), '']+d['limitations']
 (a.root/'Report.md').write_text('\n'.join(lines)+'\n');print(json.dumps({k:v for k,v in d.items() if k!='runs'},indent=2))
if __name__=='__main__':main()
