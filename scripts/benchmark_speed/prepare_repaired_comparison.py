"""Freeze a new comparison with the verified extraction repair and the original budget scope."""
import hashlib,json,secrets,shutil,sys,time
from pathlib import Path
from prepare import validate_expectation_coverage
repo=Path(__file__).resolve().parents[2];original=Path(sys.argv[1]).resolve();keyPath=Path(sys.argv[2]).resolve();repair=original/'extraction-fix';out=original/'repaired-comparison'
key=json.loads(keyPath.read_text());seed=json.loads((original/'seed.json').read_text())
validate_expectation_coverage(key,[s['id'] for s in seed['sessions']])
records={r[0]:r for r in key['sheets']['Records']['values'] if r};expectations=key['sheets']['Expected items']['values']
for session in seed['sessions']:
 assert hashlib.sha256(records[session['id']][2].encode()).hexdigest()==hashlib.sha256(session['transcript'].encode()).hexdigest()
out.mkdir(exist_ok=False)
manifest=json.loads((repair/'manifest.json').read_text())
for name,sha in manifest['repairFilesSHA256'].items():
 assert hashlib.sha256((repo/'vercel-openai-proxy/api/_lib'/name).read_bytes()).hexdigest()==sha,'Repair changed since validation'
manifest['followup']='Full cold comparison with verified extraction output repair on both arms'
manifest['keySHA256']=hashlib.sha256(keyPath.read_bytes()).hexdigest()
version='extraction-10000-v1:';manifest['ownerPrefix']=manifest['prefix']+version
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
for name in ['seed.json','records.json','aliases-before.json']:shutil.copyfile(original/name,out/name)
shutil.copyfile(keyPath,out/'key.json')
for name in ['seed','key']:assert hashlib.sha256((out/(name+'.json')).read_bytes()).hexdigest()==manifest[name+'SHA256']
shutil.copytree(original/'client',out/'client');shutil.copytree(repair/'deployment',out/'deployment',symlinks=True)
backend=out/'deployment/vercel-openai-proxy'
shutil.copyfile(Path(__file__).parent/'endpoint.ts',backend/'api/benchmark.ts')
worker=backend/'api/_lib/worker.ts';s=worker.read_text()
marker='      const result = await client.responses.create(';assert s.count(marker)==1
s=s.replace(marker,'      const providerStarted=performance.now();\n'+marker)
marker='result.usage ?? undefined, result.output_text, result.id, responseDiagnostics(result, outputLimit));';assert s.count(marker)==1
s=s.replace(marker,marker+'''\n      await database().query("UPDATE ai_payloads SET result=result || jsonb_build_object('providerSeconds',$2::double precision) WHERE job_id=$1 AND result IS NOT NULL",[job.id,(performance.now()-providerStarted)/1000]);''')
worker.write_text(s)
token=secrets.token_urlsafe(32)
(backend/'api/config.json').write_text(json.dumps({'prefix':manifest['prefix'],'runVersion':version,'tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+86400)*1000)}))
(out/'auth.json').write_text(json.dumps({'token':token,'cli':sys.argv[3:]}));(out/'auth.json').chmod(0o600)
print('Repaired comparison frozen; unique cold-run owners; original cumulative budget retained.')
