"""Read already completed diagnostic jobs into private local evidence. No inference."""
import argparse,concurrent.futures,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('run');a=p.parse_args()
r=a.root.resolve();out=r/a.run/'jobs';out.mkdir(exist_ok=True)
v=json.loads((r/a.run/'ledger.json').read_text());owner=json.loads((r/'manifest.json').read_text())['ownerPrefix']+a.run
helper=Path(__file__).with_name('fast_request.py').resolve()
def fetch(j):
 req=out/(j['id']+'.request.json');res=out/(j['id']+'.json');req.write_text(json.dumps({'action':'job','run':a.run,'id':j['id']}))
 subprocess.run(['python3',str(helper),str(r),str(req),str(res)],check=True,capture_output=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
 list(pool.map(fetch,[j for j in v['jobs'] if j['owner']==owner]))
print('Completed job responses saved privately; no inference submitted.')
