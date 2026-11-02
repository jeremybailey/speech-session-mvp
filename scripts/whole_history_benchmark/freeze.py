"""Bind source, model policy, schemas, original-only inputs and separate answer key."""
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve();repo=Path(__file__).resolve().parents[2]
validation=json.loads((root/'validation.json').read_text()) if (root/'validation.json').exists() else {'buildLog':'/tmp/whole-history-build.log','testLog':'/tmp/whole-history-tests.log'}
assert '** BUILD SUCCEEDED **' in Path(validation['buildLog']).read_text()
tests=Path(validation['testLog']).read_text();assert 'Executed ' in tests and '0 failures' in tests and 'error:' not in tests
files={}
for directory in ['combined/Sources','combined/SpeechSessionApp','combined/Tests','deployment/vercel-openai-proxy/api','deployment/vercel-openai-proxy/scripts','harness']:
 for p in (root/directory).rglob('*'):
  if p.is_file() and p.suffix in ('.swift','.ts','.json') and 'module-cache' not in str(p):files[str(p.relative_to(root))]=hashlib.sha256(p.read_bytes()).hexdigest()
for p in list((repo/'scripts/whole_history_benchmark').glob('*.py'))+list((repo/'scripts/whole_history_benchmark').glob('*.swift'))+list((repo/'scripts/whole_history_benchmark').glob('*.ts'))+[repo/'scripts/score_scorecard.py']:
 files[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
for name in ['records.json','seed.json','key.json','dataset-audit.json','manifest.json','integration.json','runtime-policy.json','grading-rubric.json','deployment/vercel-openai-proxy/package-lock.json']:
 files[name]=hashlib.sha256((root/name).read_bytes()).hexdigest()
for src,name in [(validation['buildLog'],'build.log'),(validation['testLog'],'tests.log')]:
 (root/name).write_bytes(Path(src).read_bytes())
(root/'freeze.json').write_text(json.dumps({'version':1,'files':files,'combinedBuildPassed':True,'combinedTestsPassed':True,'syntheticTestsPassed':json.loads((root/'synthetic-gates.json').read_text())['passed'],
 'sourceReconciliation':'Authoritative export originals verified, one wrong frozen-key text retained only in unchanged key',
 'timingScope':'harness, not phone wall-clock','baselineNetworkAdapter':'CLI bridge; prompt construction and app processing unchanged',
 'candidateContextDocumentation':'https://developers.openai.com/api/docs/models/gpt-6-luna','outputAllowance':64000,'contextLimit':1050000},indent=2))
print('Frozen experiment manifest; no model dispatch.')
