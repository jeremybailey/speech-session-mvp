"""Deploy diagnostics with no production domain assignment; verify aliases."""
import json,re,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve(); auth=json.loads((root/'auth.json').read_text());cli=auth['cli'];cwd=root/'deployment'
def call(args):
 p=subprocess.run(cli+args,cwd=cwd,capture_output=True,text=True)
 if p.returncode:raise RuntimeError('Diagnostic CLI failed: '+p.stderr[-1200:])
 return p.stdout,p.stderr
def aliases():
 return {a:json.loads(call(['inspect','https://'+a,'--json'])[0])['id'] for a in ['speech-session-mvp.vercel.app','speech-session-mvp-jeremy-baileys-projects.vercel.app']}
before=aliases();(root/'aliases-before.json').write_text(json.dumps(before))
out,err=call(['deploy','--prod','--skip-domain','--yes','--meta','experiment='+json.loads((root/'manifest.json').read_text())['prefix']])
(root/'deploy.log').write_text(err);deployment=re.findall(r'https://speech-session-[^\s]+\.vercel\.app',out+'\n'+err)[-1]
auth['deployment']=deployment;(root/'auth.json').write_text(json.dumps(auth));(root/'auth.json').chmod(0o600)
(root/'deployments.json').write_text(json.dumps([deployment]))
after=aliases();(root/'aliases-after.json').write_text(json.dumps(after));assert before==after,'Pilot aliases changed; stop'
print('Expiring authenticated diagnostic deployment ready; both pilot aliases unchanged.')
