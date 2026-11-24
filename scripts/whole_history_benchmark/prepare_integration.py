"""Preserve two dirty checkouts and combine them in a new private evaluation copy."""
import argparse,io,json,shutil,subprocess,tarfile
from pathlib import Path

def git(repo,*args):return subprocess.check_output(['git',*args],cwd=repo)
def snapshot(repo,out):
 out.mkdir(parents=True,exist_ok=False)
 for name,args in [('tracked.patch',('diff','--binary','HEAD')),('status.txt',('status','--porcelain=v1')),('head.txt',('rev-parse','HEAD'))]:
  (out/name).write_bytes(git(repo,*args))
 for name,files in [('tracked-files',git(repo,'diff','--name-only','HEAD').decode().splitlines()),('untracked',git(repo,'ls-files','--others','--exclude-standard').decode().splitlines())]:
  for filename in files:
   source=repo/filename
   if source.is_file():
    target=out/name/filename;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)

def integrate(recovery,care,out):
 out.mkdir(parents=True,exist_ok=False);out.chmod(0o700)
 snapshot(recovery,out/'preserved/recovery');snapshot(care,out/'preserved/care-plan')
 recovery_head=git(recovery,'rev-parse','HEAD').decode().strip();care_head=git(care,'rev-parse','HEAD').decode().strip();base=git(recovery,'merge-base',recovery_head,care_head).decode().strip()
 combined=out/'combined';combined.mkdir()
 with tarfile.open(fileobj=io.BytesIO(git(recovery,'archive',recovery_head))) as archive:archive.extractall(combined,filter='data')
 for folder in ['tracked-files','untracked']:
  for source in (out/'preserved/recovery'/folder).rglob('*'):
   if source.is_file():
    relative=source.relative_to(out/'preserved/recovery'/folder)
    if folder=='untracked' and relative.parts[0] not in ['Sources','SpeechSessionApp','Tests','vercel-openai-proxy']:continue
    target=combined/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
 paths=set(git(care,'diff','--name-only',base).decode().splitlines())|set(git(care,'ls-files','--others','--exclude-standard').decode().splitlines());conflicts=[]
 for filename in sorted(paths):
  relative=Path(filename)
  if relative.parts[0] not in ['Sources','SpeechSessionApp','SpeechSessionApp.xcodeproj','Tests','docs'] or 'project.xcworkspace' in relative.parts:continue
  target=combined/relative;incoming=care/relative
  if not incoming.exists():raise RuntimeError('Review deletion before integration: '+filename)
  baseline=subprocess.run(['git','show',base+':'+filename],cwd=recovery,capture_output=True)
  target.parent.mkdir(parents=True,exist_ok=True)
  if baseline.returncode:
   if target.exists() and target.read_bytes()!=incoming.read_bytes():conflicts.append(filename)
   else:shutil.copy2(incoming,target)
  else:
   reference=out/'merge-base.tmp';reference.write_bytes(baseline.stdout)
   if not target.exists():raise RuntimeError('Review recovery deletion: '+filename)
   merged=subprocess.run(['git','merge-file','-p',str(target),str(reference),str(incoming)],capture_output=True)
   if merged.returncode not in (0,1):raise RuntimeError('Integration failed: '+filename)
   target.write_bytes(merged.stdout)
   if merged.returncode:conflicts.append(filename)
 (out/'merge-base.tmp').unlink(missing_ok=True)
 (out/'integration.json').write_text(json.dumps({'base':base,'recoveryHead':recovery_head,'careHead':care_head,'conflicts':conflicts},indent=2))
 if conflicts:raise RuntimeError('Resolve isolated integration conflicts before dataset preparation: '+', '.join(conflicts))
 print('Original dirty checkouts preserved; private combined source prepared.')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('recovery',type=Path);p.add_argument('care',type=Path);p.add_argument('output',type=Path);a=p.parse_args();integrate(a.recovery.resolve(),a.care.resolve(),a.output.resolve())
