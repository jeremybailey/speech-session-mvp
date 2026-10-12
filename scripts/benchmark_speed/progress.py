"""Read local progress without exposing clinical text or making provider requests."""
import collections,json,sys,time
from pathlib import Path
run=Path(sys.argv[1]);trace=run/'trace';stages=collections.Counter();failed=[];cost=0
for p in trace.glob('*.receipt.json'):
 j=json.loads(p.read_text());request=p.with_name(p.name.replace('.receipt.json','.request.json'))
 stage=j.get('stage') or (json.loads(request.read_text()).get('stage','conditions') if request.exists() else 'unknown')
 stages[(stage,j.get('state','unknown'))]+=1
 cost+=int(j.get('cost_nusd') or 0)
 if j.get('state') not in ['completed','queued','running']:failed.append({'stage':stage,'state':j.get('state'),'diagnostics':(j.get('result') or {}).get('diagnostics')})
result={'run':run.name,'stages':{'/'.join(k):v for k,v in stages.items()},'knownReceiptCostUSD':cost/1e9,'failures':failed,'finished':(run/'run.json').exists()}
starts=list(trace.glob('*.send.json'))
if starts:result['elapsedMinutes']=round((time.time()-min(p.stat().st_mtime for p in starts))/60,1)
if result['finished']:result['result']=json.loads((run/'run.json').read_text())
print(json.dumps(result,indent=2))
