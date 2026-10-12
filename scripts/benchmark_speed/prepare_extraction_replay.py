"""Reopen isolated diagnostics for exact failed requests, retaining the ORIGINAL $1 scope."""
import hashlib,json,secrets,shutil,sys,time
from pathlib import Path
repo=Path(__file__).resolve().parents[2];original=Path(sys.argv[1]).resolve();out=original/'extraction-fix'
out.mkdir(exist_ok=False)
manifest=json.loads((original/'manifest.json').read_text())
manifest['followup']='Exact failed extraction replay; 10000 output limit, unchanged prompts and model'
manifest['repairFilesSHA256']={name:hashlib.sha256((repo/'vercel-openai-proxy/api/_lib'/name).read_bytes()).hexdigest() for name in ['ledger.ts','worker.ts','output-policy.ts','response-diagnostics.ts']}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
shutil.copyfile(original/'aliases-before.json',out/'aliases-before.json')
shutil.copytree(original/'deployment',out/'deployment',symlinks=True)
backend=out/'deployment/vercel-openai-proxy'
for name in ['ledger.ts','worker.ts','output-policy.ts','response-diagnostics.ts']:
 shutil.copyfile(repo/'vercel-openai-proxy/api/_lib'/name,backend/'api/_lib'/name)
ledger=backend/'api/_lib/ledger.ts';s=ledger.read_text()
s="import { assertExperimentAllowance, sharedLimit } from '../../scripts/benchmark-budget';\nconst experiment = require('../config.json');\n"+s
marker='    const reserve = reservation(model, outputTokenLimit(model, payload.stage));';assert s.count(marker)==1
s=s.replace(marker,marker+"\n    if(BigInt(budget.limit_nusd)>sharedLimit)throw Error('budget_configuration_changed');\n    await assertExperimentAllowance(db,experiment.prefix,owner,reserve);")
ledger.write_text(s)
worker=backend/'api/_lib/worker.ts';s=worker.read_text();assert s.count('  await cleanup();')==1
worker.write_text(s.replace('  await cleanup();','  // Isolated diagnostics never clean up pilot work.'))
token=secrets.token_urlsafe(32)
(backend/'api/config.json').write_text(json.dumps({'prefix':manifest['prefix'],'tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+86400)*1000)}))
(out/'auth.json').write_text(json.dumps({'token':token,'cli':sys.argv[2:]}));(out/'auth.json').chmod(0o600)
cases=[]
for arm in ['baseline-1','parallel-1']:
 for receipt in (original/arm/'trace').glob('*.receipt.json'):
  job=json.loads(receipt.read_text())
  if job.get('state')!='incomplete' or job.get('stage')!='extraction':continue
  request=receipt.with_name(receipt.name.replace('.receipt.json','.request.json'));payload=json.loads(request.read_text())
  name=arm+'-failed';target=out/(name+'.json');target.write_text(json.dumps(payload))
  cases.append({'name':name,'file':target.name,'originalJobID':job['id'],'payloadSHA256':hashlib.sha256(target.read_bytes()).hexdigest()})
assert len(cases)==2
(out/'cases.json').write_text(json.dumps(cases,indent=2))
print('Two exact failed requests frozen; existing experiment prefix and cap preserved. No network calls.')
