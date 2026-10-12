"""Create hash-bound LOCAL review material; never transmit the answer key to a checker."""
import argparse,hashlib,json
from pathlib import Path

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('run');a=p.parse_args();root=a.root.resolve();out=root/a.run
 key=json.loads((root/'key.json').read_text());manifest=json.loads((root/'manifest.json').read_text())
 assert digest(root/'key.json')==manifest['keySHA256'],'Key changed'
 selected=set(manifest['records'].values());records={r[0]:r for r in key['sheets']['Records']['values'] if r and r[0] in selected}
 bundle={'keySHA256':digest(root/'key.json'),'run':a.run,'records':[],'scope':'Local human/agent semantic review; Draft labels stay provisional. No keyword-based clinical matching.'}
 for path in sorted(out.glob('*.output.json')):
  output=json.loads(path.read_text());rid=output['recordID'];assert rid in records
  assert hashlib.sha256(records[rid][2].encode()).hexdigest()==output['sourceSHA256']
  expected=[r for r in key['sheets']['Expected items']['values'] if len(r)>1 and r[1]==rid]
  bundle['records'].append({'recordID':rid,'outputSHA256':digest(path),'sourceSHA256':output['sourceSHA256'],'expectedRows':expected,'entries':output['entries']})
 (out/'review-input.json').write_text(json.dumps(bundle,indent=2))
 print('Prepared local review material for',len(bundle['records']),'records; no judgments inferred.')
if __name__=='__main__':main()
