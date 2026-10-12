"""Purge only this experiment's remote payloads, verify zero, then remove temporary deployments."""
import json,os,re,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve();tools=Path(__file__).resolve().parent;auth=json.loads((root/'auth.json').read_text());cli=auth['cli']
for action in ['status','purge']:
 request=root/(action+'-cleanup-request.json');response=root/(action+'-cleanup.json')
 request.write_text(json.dumps({'action':action,'run':'baseline-1'}))
 subprocess.run(['python3',os.environ.get('BENCHMARK_REQUEST_HELPER',str(tools/'request.py')),str(root),str(request),str(response)],check=True)
 result=json.loads(response.read_text());assert 'error' not in result,result.get('error')
 if action=='purge':assert result=={'job_payloads':0,'workflow_payloads':0,'upload_parts':0},'Cleanup not verified'
for deployment in json.loads((root/'deployments.json').read_text()):
 p=subprocess.run(cli+['remove',deployment,'--yes'],cwd=root/'deployment',capture_output=True,text=True)
 if p.returncode:raise RuntimeError('Temporary deployment removal failed; see provider dashboard')
before=json.loads((root/'aliases-before.json').read_text());after={}
for alias in before:
 p=subprocess.run(cli+['inspect',alias],cwd=root/'deployment',capture_output=True,text=True,check=True)
 after[alias]=re.search(r'\bid\s+(dpl_\w+)',p.stdout+p.stderr).group(1)
(root/'aliases-cleanup.json').write_text(json.dumps(after,indent=2));assert before==after,'Pilot alias changed'
# Keep only accounting and source-local private evidence; remove access material.
(root/'auth.json').unlink();(root/'deployment/vercel-openai-proxy/api/config.json').unlink()
print('Scoped remote payloads verified zero; listed diagnostic deployments removed; local access files removed.')
