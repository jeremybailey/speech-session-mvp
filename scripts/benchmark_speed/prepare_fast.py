"""Prepare a LOCAL isolated experiment; no deployment or inference. Requires a previously
cleaned benchmark directory as the frozen seed and diagnostic endpoint template."""
import argparse,hashlib,json,secrets,shutil,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('previous',type=Path);p.add_argument('output',type=Path);p.add_argument('cli',nargs='+');a=p.parse_args()
root=Path(__file__).resolve().parents[2];previous=a.previous.resolve();out=a.output.resolve()
assert json.loads((previous/'purge-cleanup.json').read_text())=={'job_payloads':0,'workflow_payloads':0,'upload_parts':0}
out.mkdir(parents=True,exist_ok=False)
for name in ['seed.json','key.json','records.json','aliases-before.json']:shutil.copy2(previous/name,out/name)
shutil.copytree(previous/'deployment',out/'deployment',ignore=shutil.ignore_patterns('node_modules','.env*','config.json'),symlinks=True)
backend=out/'deployment/vercel-openai-proxy'
for directory in ['api/_lib','scripts']:
 for f in (root/'vercel-openai-proxy'/directory).glob('*.ts'):shutil.copy2(f,backend/directory/f.name)
# This configuration exists only in the isolated expiring diagnostic entrypoint.
p=backend/'api/benchmark.ts';s=p.read_text().replace(" const b=req.body??{};", " process.env.FAST_DETAILS_EXPERIMENT_ENABLED='true';\n const b=req.body??{};");s=s.replace("(p.result->>'providerSeconds')::double precision", "COALESCE((p.result->>'providerSeconds')::double precision,(p.result->'diagnostics'->>'providerSeconds')::double precision)")
p.write_text(s)
manifest=json.loads((previous/'manifest.json').read_text())
manifest.update(scope='Fast details only; full flow remains separately measured',ownerPrefix=manifest['prefix']+'fast-details-app:bench-v1:',plannedOrder=['parallel-1'],experimentLimitUSD=2.25)
manifest.pop('replacementComparison',None)
manifest['frozenFilesSHA256']={str(f.relative_to(backend)):hashlib.sha256(f.read_bytes()).hexdigest() for f in (backend/'api/_lib').glob('*.ts')}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
# Preserve the last known accounting snapshot; refresh before any paid admission.
shutil.copy2(previous/'status-cleanup.json',out/'prior-accounting.json')
token=secrets.token_urlsafe(32)
(out/'auth.json').write_text(json.dumps({'token':token,'cli':a.cli}));(out/'auth.json').chmod(0o600)
(backend/'api/config.json').write_text(json.dumps({'prefix':manifest['prefix'],'runVersion':'fast-details-app:bench-v1:','tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+86400)*1000)}))
print('Local fast-details dataset and isolated diagnostic configuration prepared. No deployment or inference.')
