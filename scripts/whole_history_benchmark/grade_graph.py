"""Hash-bound CLI for existing scorecard Conditions and Relationships review."""
import argparse,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from score_scorecard import digest,score_graph
p=argparse.ArgumentParser();p.add_argument('--key',required=True);p.add_argument('--output',required=True);p.add_argument('--judgments',required=True);p.add_argument('--report',required=True);p.add_argument('--include-draft',action='store_true');a=p.parse_args()
k,o,j=[json.loads(Path(x).read_text()) for x in [a.key,a.output,a.judgments]]
assert j['keySHA256']==digest(a.key),'Key changed; review again'
assert j['outputSHA256']==digest(a.output),'Output changed; review again'
r=score_graph(k,o,j,a.include_draft);r.update(keySHA256=digest(a.key),outputSHA256=digest(a.output),evaluator=j['evaluator']);Path(a.report).write_text(json.dumps(r,indent=2)+'\n')
