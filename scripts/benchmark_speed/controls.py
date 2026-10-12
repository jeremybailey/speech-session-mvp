"""Optional live synthetic Decisions checks; expected answers never enter request payloads."""
import json,sys
from pathlib import Path
from shadow import call
root=Path(sys.argv[1]).resolve();out=root/'controls';out.mkdir(exist_ok=False)
rows=[]
for case in json.loads((root/'controls.json').read_text()):
 result,elapsed=call(root,{'action':'decisions','run':'controls-1','payload':case['payload']},out/case['name'])
 answers=result.get('result',{}).get('decision',{}).get('answers',[])
 answer=answers[0] if len(answers)==1 else {}
 probabilities={p['value']:p['probability'] for p in answer.get('probabilities',[])}
 accepted=(result.get('state')=='completed' and answer.get('choice')=='Pass' and answer.get('confidence',0)>=.99 and probabilities.get('Pass',0)>=.99)
 rows.append({'name':case['name'],'expected':case['expected'],'choice':answer.get('choice'),'confidence':answer.get('confidence'),'accepted':accepted,'agrees':answer.get('choice')==case['expected'],'elapsedSeconds':elapsed,'costNUSD':result.get('cost_nusd'),'state':result.get('state')})
(out/'comparison.json').write_text(json.dumps(rows,indent=2))
print(json.dumps(rows,indent=2))
