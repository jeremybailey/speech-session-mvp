"""Private review projections only. Never import candidate proposals into SessionStore."""
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve();records=json.loads((root/'records.json').read_text())['records']
for name in ['single','check']:
 for n in range(1,4):
  out=root/f'{name}-{n}';source=out/'output.json'
  if not source.exists():continue
  raw=json.loads(source.read_text());all_ids=[]
  for kind in ('details','conditions','relationships','carePlans'):all_ids += [{'id':e['id'],'kind':kind,**e} for e in raw[kind]]
  (out/'graph-projection.json').write_text(json.dumps({'entities':all_ids,'clinicallyVerified':False,'candidateSHA256':hashlib.sha256(source.read_bytes()).hexdigest()},indent=2))
  for record in records:
   entries=[]
   for d in raw['details']:
    if d['recordID']!=record['id']:continue
    entries.append({**d,'sourceSessionID':d['recordID'],'visible':True,'accepted':False,'experimentalUnverifiedProposal':True})
   result={'recordID':record['id'],'sourceSHA256':record['sourceSHA256'],'entries':entries,'mode':f'{name}-{n}','clinicallyVerified':False}
   (out/(record['id']+'.output.json')).write_text(json.dumps(result,indent=2,ensure_ascii=False))
print('Candidate review projections written only in private benchmark folders; no app store writes.')
