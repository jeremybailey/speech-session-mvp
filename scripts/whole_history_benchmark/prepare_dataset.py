"""Freeze original sources and a separate, unchanged scorecard. No inference."""
import argparse, hashlib, json, re, shutil
from pathlib import Path

def digest(data): return hashlib.sha256(data).hexdigest()
def write(path, value): path.write_text(json.dumps(value, indent=2, ensure_ascii=False)+'\n'); path.chmod(0o600)
def prepare(export, key_path, out):
    out.mkdir(parents=True, exist_ok=True)
    manifest_data=(export/'manifest.json').read_bytes(); manifest=json.loads(manifest_data)
    index=next(f for f in manifest['files'] if f['destination']=='sessions.json')
    data=(export/index['archiveName']).read_bytes()
    assert digest(data)==index['sha256'], 'Authoritative session export hash mismatch'
    saved=json.loads(data); sessions={s['id']:s for s in saved['sessions']}
    key_data=key_path.read_bytes(); key=json.loads(key_data)
    rows=[r for r in key['sheets']['Records']['values'] if r and re.fullmatch(r'[A-Fa-f0-9-]{36}',str(r[0]))]
    originals={r['id']:r for r in manifest['records']}; assert len(rows)==20 and len({r[0] for r in rows})==20
    records=[]; seed=[]; discrepancies=[]
    for row in rows:
        rid=row[0]; original=originals[rid]; raw=(export/original['sourceTextFile']).read_bytes()
        assert digest(raw)==original['sourceTextSHA256'], f'Cannot establish original: {rid}'
        text=raw.decode('utf-8'); metadata=sessions[rid]
        if digest(row[2].encode())!=digest(raw):
            # Only reconcile with the explicit hash frozen in this key's metadata.
            assert original['sourceTextSHA256'] in json.dumps(row), f'Unreconciled source mismatch: {rid}'
            discrepancies.append({'recordID':rid,'keyTextSHA256':digest(row[2].encode()),'authoritativeSHA256':digest(raw),
                                  'resolution':'Verified original export source; answer key unchanged; review source directly.'})
        record={'id':rid,'date':metadata['date'],'title':original['title'],'text':text,
                'sourceReference':original['sourceTextFile'],'sourceSHA256':digest(raw)}
        records.append(record)
        # Explicit allowlist: never copy saved generated fields, preferences or profile.
        seed.append({'id':rid,'date':metadata['date'],'title':original['title'],'transcript':text,
                     'inputType':metadata.get('inputType','documentFile'),'entryIntent':metadata.get('entryIntent','clinicalVisit')})
    write(out/'records.json',{'version':1,'records':records})
    write(out/'seed.json',{'version':saved['version'],'sessions':seed})
    (out/'key.json').write_bytes(key_data); (out/'key.json').chmod(0o600)
    write(out/'dataset-audit.json',{'recordCount':20,'sourceBytes':sum(len(r['text'].encode()) for r in records),
      'exportManifestSHA256':digest(manifest_data),'sessionsSHA256':digest(data),'keySHA256':digest(key_data),
      'recordsSHA256':digest((out/'records.json').read_bytes()),'discrepancies':discrepancies,
      'grading':'Draft labels are provisional; expectations must never enter processing requests.'})
    print(f'Frozen {len(records)} authoritative originals; {len(discrepancies)} documented reconciliation(s).')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('export',type=Path);p.add_argument('key',type=Path);p.add_argument('output',type=Path);a=p.parse_args();prepare(a.export,a.key,a.output)
