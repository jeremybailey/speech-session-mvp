"""Freeze a condition/overview-only repair replay; never call it cold reprocessing."""
import hashlib,json,secrets,shutil,sys,time
from pathlib import Path

previous=Path(sys.argv[1]).resolve();out=previous.parent/'downstream-completion-replay'
run=previous/'baseline-1';result=json.loads((run/'run.json').read_text())
assert not result['completed'] and result['sourceOccurrencesPreserved']
assert all(p['completed'] for p in result['phases'] if p['phase'].startswith('record:'))
source=lambda p:{s['id']:s['transcript'] for s in json.loads(p.read_text())['sessions']}
assert source(previous/'seed.json')==source(run/'store/sessions.json')
out.mkdir(exist_ok=False)
for name in ['seed.json','key.json','records.json','aliases-before.json','deployments.json']:shutil.copyfile(previous/name,out/name)
shutil.copytree(previous/'client',out/'client');shutil.copytree(previous/'deployment',out/'deployment',symlinks=True)
shutil.copytree(run/'store',out/'snapshot')
backend=out/'deployment/vercel-openai-proxy';path=backend/'api/_lib/condition-workflow.ts';text=path.read_text()
path.with_name('condition-workflow.before-empty.ts').write_text(text)
for old,new in [
 ('function validGroup(g: Group) {','function validGroup(g: Group, allowEmpty=false) {'),
 ('Array.isArray(g.entryIDs) && g.entryIDs.length>0','Array.isArray(g.entryIDs) && (allowEmpty || g.entryIDs.length>0)'),
 ('value.groups.forEach(validGroup);','value.groups.forEach(group=>validGroup(group));'),
 ('      validGroup(group);','      validGroup(group,true);\n      if(!group.entryIDs.length) continue;')
]:
 assert text.count(old)==1; text=text.replace(old,new)
path.write_text(text)
manifest=json.loads((previous/'manifest.json').read_text())
manifest.update(scope='Saved-record downstream completion replay only; NOT cold full reprocessing',ownerPrefix=manifest['prefix']+'downstream-empty-heading-v1:',conditionFormattingRepairSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),plannedOrder=['controls-1'],snapshotSource=str(run/'store'))
manifest['snapshotSHA256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (out/'snapshot').iterdir() if p.is_file()}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
auth=json.loads((previous/'auth.json').read_text());token=secrets.token_urlsafe(32)
(out/'auth.json').write_text(json.dumps({'token':token,'cli':auth['cli']}));(out/'auth.json').chmod(0o600)
(backend/'api/config.json').write_text(json.dumps({'prefix':manifest['prefix'],'runVersion':'downstream-empty-heading-v1:','tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+86400)*1000)}))
print('Saved-record replay frozen; original cap retained. Run replay with --resume-snapshot.')
