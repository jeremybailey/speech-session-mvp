"""Add only exact duplicate-heading formatting consolidation to the frozen backend."""
import hashlib,json,secrets,shutil,sys,time
from pathlib import Path

previous=Path(sys.argv[1]).resolve();out=previous.parent/'all-completion-repairs'
out.mkdir(exist_ok=False)
for name in ['seed.json','records.json','key.json','aliases-before.json','deployments.json']:
    shutil.copyfile(previous/name,out/name)
shutil.copytree(previous/'client',out/'client')
shutil.copytree(previous/'deployment',out/'deployment',symlinks=True)
backend=out/'deployment/vercel-openai-proxy'
path=backend/'api/_lib/condition-workflow.ts';old=path.read_text()
path.with_name('condition-workflow.baseline.ts').write_text(old)
a='''    const groups:Group[]=response.groups.map((g:any)=>({name:g.name,bodySystem:g.bodySystem,
      isPrimary:g.isPrimary,reason:g.reason,entryIDs:restore(g.entryIDs)}));'''
b='''    const proposedGroups:Group[]=response.groups.map((g:any)=>({name:g.name,bodySystem:g.bodySystem,
      isPrimary:g.isPrimary,reason:g.reason,entryIDs:restore(g.entryIDs)}));
    const groups:Group[]=[];
    for(const group of proposedGroups) {
      validGroup(group);
      const same=groups.find(g=>g.name===group.name && g.bodySystem===group.bodySystem);
      if(same) {
        requireValue(same.isPrimary===group.isPrimary);
        same.entryIDs.push(...group.entryIDs);
      } else groups.push(group);
    }'''
assert old.count(a)==1;path.write_text(old.replace(a,b))
manifest=json.loads((previous/'manifest.json').read_text())
manifest['scope']='Fresh cold full run with extraction, overview ID encoding, and exact duplicate-heading formatting repairs shared by any compared arms'
manifest['conditionFormattingRepairSHA256']=hashlib.sha256(path.read_bytes()).hexdigest()
version='all-completion-repairs-v1:';manifest['ownerPrefix']=manifest['prefix']+version
manifest['plannedOrder']=['baseline-1']
manifest['runLimitReason']='One fresh baseline first. Further cold runs require enough of the original $1 cap for actual spending plus full in-flight reservations.'
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
auth=json.loads((previous/'auth.json').read_text());token=secrets.token_urlsafe(32)
(backend/'api/config.json').write_text(json.dumps({'prefix':manifest['prefix'],'runVersion':version,'tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+86400)*1000)}))
(out/'auth.json').write_text(json.dumps({'token':token,'cli':auth['cli']}));(out/'auth.json').chmod(0o600)
print('Exact-heading repair frozen; inference and independent verification unchanged; original cap retained.')
