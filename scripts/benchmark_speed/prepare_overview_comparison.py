"""Freeze the verified citation encoding on both arms, preserving the original budget scope."""
import hashlib,json,secrets,shutil,sys,time
from pathlib import Path
from prepare import validate_expectation_coverage

previous=Path(sys.argv[1]).resolve();repair=previous/'overview-reference-fix'
out=previous.parent/'completion-repaired-comparison'
for i in range(1,4):
    result=json.loads((repair/f'controls-{i}/result.json').read_text())
    assert result['completed'], 'Overview completion repair has not passed all three replays'
manifest=json.loads((repair/'manifest.json').read_text())
assert hashlib.sha256((repair/'client/HealthSummaryModel.swift').read_bytes()).hexdigest()==manifest['clientRepairSHA256']
seed=json.loads((previous/'seed.json').read_text());key=json.loads((previous/'key.json').read_text())
validate_expectation_coverage(key,[s['id'] for s in seed['sessions']])
assert hashlib.sha256((previous/'key.json').read_bytes()).hexdigest()==manifest['keySHA256']
out.mkdir(exist_ok=False)
for name in ['seed.json','records.json','key.json','aliases-before.json']:shutil.copyfile(previous/name,out/name)
shutil.copytree(repair/'client',out/'client')
shutil.copytree(previous/'deployment',out/'deployment',symlinks=True)
backend=out/'deployment/vercel-openai-proxy'
shutil.copyfile(Path(__file__).parent/'endpoint.ts',backend/'api/benchmark.ts')
manifest['scope']='Fresh cold full runs; extraction output repair and request-only overview citation encoding identical on both arms'
manifest.pop('snapshotFilesSHA256',None)
version='completion-repair-v1:';manifest['ownerPrefix']=manifest['prefix']+version
manifest['plannedOrder']=['parallel-1','baseline-1']
manifest['runLimitReason']='Original cumulative $1 cap retained; repeated runs only if safely fundable'
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
auth=json.loads((previous/'auth.json').read_text());token=secrets.token_urlsafe(32)
(backend/'api/config.json').write_text(json.dumps({'prefix':manifest['prefix'],'runVersion':version,'tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+86400)*1000)}))
(out/'auth.json').write_text(json.dumps({'token':token,'cli':auth['cli']}));(out/'auth.json').chmod(0o600)
print('Both completion repairs frozen for both arms; original cumulative cap retained.')
