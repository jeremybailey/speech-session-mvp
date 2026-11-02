"""Purge only the experiment's remote clinical payloads, retaining all accounting."""
import hashlib,json,subprocess,sys
from pathlib import Path
from run import request,write
root=Path(sys.argv[1]).resolve();auth=json.loads((root/'auth.json').read_text());cli=auth['cli']
status=request(root,'baseline-1',{'action':'status'},root/'cleanup-trace');write(root/'status-cleanup.json',status)
result=request(root,'baseline-1',{'action':'purge'},root/'cleanup-trace');assert result=={'job_payloads':0,'workflow_payloads':0,'upload_parts':0},'Scoped purge not verified';write(root/'purge-cleanup.json',result)
removed=[]
for deployment in json.loads((root/'deployments.json').read_text()):
 p=subprocess.run(cli+['remove',deployment,'--yes'],cwd=root/'deployment',capture_output=True,text=True)
 assert p.returncode==0,'Diagnostic removal failed; access credential retained for cleanup'
 removed.append(deployment)
before=json.loads((root/'aliases-before.json').read_text());after={}
for alias in before:
 p=subprocess.run(cli+['inspect','https://'+alias,'--json'],cwd=root/'deployment',capture_output=True,text=True,check=True)
 after[alias]=json.loads(p.stdout)['id']
assert before==after,'Pilot routing changed';write(root/'aliases-cleanup.json',after)
config=root/'deployment/vercel-openai-proxy/api/config.json';redacted=json.loads(config.read_text());redacted.pop('tokenHash',None);write(root/'diagnostic-config-redacted.json',redacted)
access=[]
for path in [root/'auth.json',config,root/'unused-preparation-v1/vercel-openai-proxy/api/config.json']:
 if path.exists():access.append({'path':str(path.relative_to(root)),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()});path.unlink()
write(root/'cleanup-attestation.json',{'remotePayloads':result,'deploymentsRemoved':removed,'temporaryAccessFilesRemoved':access,'pilotAliasesUnchanged':True,'accountingRetained':True,'unresolvedChargesRetained':True})
print('Scoped remote payloads purged, diagnostic deployments removed, temporary access files removed; pilot domains unchanged. Accounting retained.')
