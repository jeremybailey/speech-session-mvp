"""Deploy expiring diagnostics without assigning domains; verify pilot aliases unchanged."""
import json,re,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve();auth=json.loads((root/'auth.json').read_text());cli=auth['cli'];cwd=root/'deployment'
def run(args):
 p=subprocess.run(cli+args,cwd=cwd,capture_output=True,text=True)
 if p.returncode: raise RuntimeError('Vercel command failed: '+p.stderr[-1400:])
 return p.stdout,p.stderr
def inspect(alias):
 out,err=run(['inspect',alias]);text=out+err
 return re.search(r'\bid\s+(dpl_\w+)',text).group(1)
aliases=['speech-session-mvp.vercel.app','speech-session-mvp-jeremy-baileys-projects.vercel.app']
before={a:inspect(a) for a in aliases}
if (root/'aliases-before.json').exists():assert before==json.loads((root/'aliases-before.json').read_text()),'Pilot aliases changed since experiment start'
else:(root/'aliases-before.json').write_text(json.dumps(before))
out,err=run(['deploy','--prod','--skip-domain','--yes','--meta','experiment='+json.loads((root/'manifest.json').read_text())['prefix']]);(root/'deploy.log').write_text(err);(root/'deployment-result.txt').write_text(out)
try: deployment=json.loads(out)['deployment']['url']
except (ValueError,KeyError):deployment=re.findall(r'https://[^\s]+\.vercel\.app',out)[-1]
history=root/'deployments.json';items=json.loads(history.read_text()) if history.exists() else ([auth['deployment']] if 'deployment' in auth else []);items.append(deployment);history.write_text(json.dumps(items,indent=2))
auth['deployment']=deployment;(root/'auth.json').write_text(json.dumps(auth));(root/'auth.json').chmod(0o600)
after={a:inspect(a) for a in aliases};(root/'aliases-after.json').write_text(json.dumps(after));assert before==after,'Alias changed: stop diagnostics'
print('Isolated diagnostic deployment ready; pilot aliases unchanged.')
