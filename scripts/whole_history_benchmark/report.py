"""Private accounting/timing report. Failures never become speed improvements."""
import csv,json,statistics,sys
from pathlib import Path

def write(path,obj):path.write_text(json.dumps(obj,indent=2,ensure_ascii=False)+'\n')
def summarize(jobs):
 settled=[j for j in jobs if j['cost_nusd'] is not None];unresolved=[j for j in jobs if j['cost_nusd'] is None]
 timings=[float(j['provider_seconds']) for j in jobs if j.get('provider_seconds') is not None]
 def queue(j):
  from datetime import datetime
  return (datetime.fromisoformat(j['started_at'].replace('Z','+00:00'))-datetime.fromisoformat(j['created_at'].replace('Z','+00:00'))).total_seconds() if j.get('started_at') else None
 queues=[q for j in jobs if (q:=queue(j)) is not None]
 return {'providerRequests':len([j for j in jobs if j.get('started_at')]),'jobs':len(jobs),'completedJobs':sum(j['state']=='completed' for j in jobs),
  'inputTokens':sum(int(j.get('input_tokens') or 0) for j in jobs),'outputTokens':sum(int(j.get('output_tokens') or 0) for j in jobs),
  'knownReasoningTokens':sum(int((j.get('diagnostics') or {}).get('reasoningTokens') or 0) for j in jobs),
  'tokenUsageUnavailableJobs':[j['id'] for j in jobs if j.get('input_tokens') is None or j.get('output_tokens') is None],
  'reasoningUsageUnavailableJobs':[j['id'] for j in jobs if (j.get('diagnostics') or {}).get('reasoningTokens') is None],
  'settledCostUSD':sum(int(j['cost_nusd']) for j in settled)/1e9,'unresolvedReservationUSD':sum(int(j['reserve_nusd']) for j in unresolved)/1e9,
  'unresolvedJobs':[j['id'] for j in unresolved],'providerSecondsSum':sum(timings) if timings else None,'providerTimingCount':len(timings),
  'queueSecondsSum':sum(queues) if queues else None,'states':{s:sum(j['state']==s for j in jobs) for s in sorted({j['state'] for j in jobs})}}

def main(root):
 ledgerpath=root/'status-cleanup.json' if (root/'status-cleanup.json').exists() else root/'latest-accounting.json'
 ledger=json.loads(ledgerpath.read_text());jobs=ledger['jobs'];records=json.loads((root/'records.json').read_text())['records'];rows=[]
 for repetition in range(1,4):
  for arm,name in [('A','baseline'),('B','single'),('C','check')]:
   out=root/f'{name}-{repetition}';p=out/'run.json'
   if not p.exists():continue
   run=json.loads(p.read_text());own=[j for j in jobs if j['owner'].endswith(f':{name}-{repetition}')]
   shared=[j for j in jobs if j['owner'].endswith(f':single-{repetition}')] if arm=='C' else []
   metric=summarize(own+shared);metric.update(arm=arm,repetition=repetition,completed=run.get('completed',False),ownPass=summarize(own),
       elapsedSeconds=run.get('elapsedSeconds'),failure=run.get('failure'),issues=run.get('issues'),timingScope='harness including CLI transport, not phone wall-clock')
   if arm=='C':
    b=json.loads((root/f'single-{repetition}/run.json').read_text());metric['elapsedSeconds']=(run.get('elapsedSeconds') or 0)+(b.get('elapsedSeconds') or 0)
    metric['generationSharedWithB']=True
   rows.append(metric)
 medians={}
 for arm in ('A','B','C'):
  complete=[r for r in rows if r['arm']==arm and r['completed'] and not r['unresolvedJobs']]
  medians[arm]={'completeRepetitions':len(complete),'elapsedSeconds':statistics.median(r['elapsedSeconds'] for r in complete) if complete else None,'settledCostUSD':statistics.median(r['settledCostUSD'] for r in complete) if complete else None}
 comparable=all(medians[a]['completeRepetitions']==3 for a in medians)
 write(root/'cost-timing.json',{'medians':medians,'threeCompleteRepetitionsPerArm':comparable,'runs':rows,'actualExperiment':summarize(jobs),'cumulativeExperimentAccounting':ledger.get('experimentAccounting'),'sharedPilotBudget':ledger.get('budget'),'sharedGenerationChargedOnce':True})
 actual=summarize(jobs);lines=['# Whole-history comparison','',
  'Private controlled replay of 20 authoritative saved-text records using the combined care-plan and recovery code. Both original checkouts were preserved. No app release or production routing change.',
  '', 'Results are provisional: the frozen answer key has Draft labels, and failed or incomplete runs cannot establish accuracy or a speed improvement.', '',
  '| Arm | Complete | Harness elapsed (s) | Attributed requests | Settled USD | Unresolved USD |','|---|---:|---:|---:|---:|---:|']
 for row in rows:
  seconds=f"{row['elapsedSeconds']:.2f}" if row['elapsedSeconds'] is not None else 'Unavailable'
  state='Not dispatched' if row['arm']=='C' and row['ownPass']['providerRequests']==0 else str(row['completed'])
  lines.append(f"| {row['arm']}{row['repetition']} | {state} | {seconds} | {row['providerRequests']} | {row['settledCostUSD']:.6f} | {row['unresolvedReservationUSD']:.6f} |")
 lines += ['',f"Actual experiment spending: ${actual['settledCostUSD']:.6f} settled, ${actual['unresolvedReservationUSD']:.6f} reserved/unresolved. B's generation is attributed in full to both B and C above and charged once in this total.",
  '', 'This is a fresh replay after the citation recovery fix. Completion and failure details for every arm are recorded in cost-timing.json and each run.json. Failed runs are excluded from speed comparisons.',
  '', 'A retains the current pipeline and 100-second provider deadline. Candidate B/C use Luna medium, 64,000 output tokens including reasoning, and a 240-second provider deadline inside a 300-second diagnostic function. All timing is harness timing, not phone performance. Candidate output must pass local identity and quotation gates.',
  '', 'One frozen-key source-text mismatch was reconciled against the authoritative export and its pre-existing hash. The answer key remains unchanged. That record has no item expectations and cannot be counted as a scored accuracy pass.',
  '', 'The frozen key also contains conflicting duplicate C001 rows, which are excluded pending key review. No key labels were changed. Quotation-integrity checks are recorded per record separately from semantic grading. They do not establish clinical equivalence.',
  '', 'See cost-timing.json for tokens, per-stage timing availability, job states and outstanding reservations; per-record-review.csv and regression-review.json for output integrity and review status. No failed run contributes to median speed or cost acceptance. Complete outputs require frozen-key semantic review of details, conditions, relationships, ownership, negation and care-plan equivalence before advancement.',
  '', 'Recommendation: retain the current pipeline while resolving any observed failures. Do not advance aggregation without three complete comparisons, individual semantic review, no unresolved clinically material regressions, lower median cost and at least 50% lower median harness elapsed time. Draft-only grading remains provisional.']
 (root/'comparison-report.md').write_text('\n'.join(lines)+'\n')
 # Integrity evidence is explicitly separate from semantic grading. Do not turn
 # missing outputs or local quote matches into a clinical accuracy pass.
 reviews=[];texts={r['id']:r['text'] for r in records}
 for row in rows:
  arm=row['arm'];rep=row['repetition'];out=root/f"{ {'A':'baseline','B':'single','C':'check'}[arm]}-{rep}";candidate=json.loads((out/'output.json').read_text()) if (out/'output.json').exists() else None
  for record in records:
   if arm=='A':
    p=out/(record['id']+'.output.json');entities=json.loads(p.read_text())['entries'] if p.exists() else []
    integrity=[]
    for entry in entities:
     citations=entry.get('evidence',{}).get('assessment',{}).get('citations',[]);integrity.append({'id':entry['id'],'quoteFound':bool(citations) and all(c.get('excerpt') and c['excerpt'] in record['text'] for c in citations),'citationCount':len(citations),'visible':entry.get('visible'),'appAccepted':entry.get('accepted')})
   else:
    entities=[e for e in (candidate or {}).get('details',[]) if e.get('recordID')==record['id']]
    integrity=[{'id':e['id'],'quoteFound':bool(e.get('sources')) and all(s.get('recordID') in texts and s.get('quote') and s['quote'] in texts[s['recordID']] for s in e.get('sources',[]))} for e in entities]
   reviews.append({'arm':arm,'repetition':rep,'recordID':record['id'],'sourceSHA256':record['sourceSHA256'],'detailCount':len(entities),'runComplete':row['completed'],
    'semanticReview':'Pending semantic review; no clinical equivalence claim','integrity':integrity,
    'omissionAssessment':'Not scored from partial/failed run' if not row['completed'] else 'Requires frozen-key semantic review before any future advancement'})
 write(root/'regression-review.json',reviews)
 with (root/'per-record-review.csv').open('w') as f:
  writer=csv.writer(f);fields=['arm','repetition','recordID','sourceSHA256','detailCount','runComplete','semanticReview','omissionAssessment'];writer.writerow(fields)
  writer.writerows([[r[k] for k in fields] for r in reviews])
 print('Private comparison, accounting and per-record integrity reports written; semantic review status is explicit.')
if __name__=='__main__':main(Path(sys.argv[1]).resolve())
