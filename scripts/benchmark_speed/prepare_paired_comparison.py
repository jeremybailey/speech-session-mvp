"""Freeze identical completion repairs for a cold pair, retaining cumulative accounting."""
import hashlib,json,secrets,shutil,sys,time
from pathlib import Path
previous=Path(sys.argv[1]).resolve();out=previous.parent/'paired-comparison-150'
assert json.loads((previous/'controls-1/run.json').read_text())['completed']
out.mkdir(exist_ok=False)
for name in ['seed.json','key.json','records.json','aliases-before.json']:shutil.copyfile(previous/name,out/name)
for name in ['client','deployment']:shutil.copytree(previous/name,out/name,symlinks=True)
backend=out/'deployment/vercel-openai-proxy'
shutil.copyfile(Path(__file__).resolve().parents[2]/'vercel-openai-proxy/scripts/benchmark-budget.ts',backend/'scripts/benchmark-budget.ts')
manifest=json.loads((previous/'manifest.json').read_text())
for key in ['snapshotSource','snapshotSHA256']:manifest.pop(key,None)
manifest.update(scope='Cold full pipeline comparison with identical completion repairs',ownerPrefix=manifest['prefix']+'paired-150-v1:',plannedOrder=['parallel-1','baseline-1'],experimentLimitUSD=1.5,priorExperimentCostUSD=.668137,budgetAuthorization='User approved cumulative $1.50 on 2026-10-11; shared $5 unchanged')
manifest['frozenFilesSHA256']={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for base in [out/'client',backend/'api/_lib'] for p in base.rglob('*.swift' if base.name=='client' else '*.ts')}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
token=secrets.token_urlsafe(32)
(out/'auth.json').write_text(json.dumps({'token':token,'cli':sys.argv[2:]}));(out/'auth.json').chmod(0o600)
(backend/'api/config.json').write_text(json.dumps({'prefix':manifest['prefix'],'runVersion':'paired-150-v1:','tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+86400)*1000)}))
print('Fresh cold pair frozen; all historical experiment spending retained.')
