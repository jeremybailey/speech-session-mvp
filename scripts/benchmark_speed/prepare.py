"""Freeze build 10 inputs and create a private, isolated diagnostic workspace. No deployment."""
import argparse,hashlib,json,secrets,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def source(ref,path):return subprocess.check_output(['git','show',f'{ref}:{path}'],cwd=ROOT)
def validate_expectation_coverage(key,record_ids):
 expectations=key['sheets']['Expected items']['values']
 for rid in record_ids:
  assert any(len(r)>2 and r[1]==rid and r[2]=='Must appear' for r in expectations),'Selected record has no positive answer-key expectations'
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--archive',required=True);p.add_argument('--key',required=True);p.add_argument('--records',required=True);a=p.parse_args()
 out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=False)
 archive=Path(a.archive);key=Path(a.key);records=json.loads(Path(a.records).read_text());assert len(records)==5 and len(set(records.values()))==5
 manifest=json.loads((archive/'manifest.json').read_text());mr={r['id']:r for r in manifest['records']}
 frozen=json.loads(key.read_text());rows=frozen['sheets']['Records']['values']
 selected={r[0]:r for r in rows if r and r[0] in records.values()};assert len(selected)==5
 validate_expectation_coverage(frozen,records.values())
 for rid in records.values():
  raw=(archive/mr[rid]['sourceTextFile']).read_bytes()
  assert hashlib.sha256(raw).hexdigest()==mr[rid]['sourceTextSHA256']==hashlib.sha256(selected[rid][2].encode()).hexdigest()
  assert not any('duplicate' in str(c).lower() for c in selected[rid][3:]),'Duplicate-marked record selected'
 (out/'key.json').write_bytes(key.read_bytes());(out/'records.json').write_text(json.dumps(records,indent=2))
 # Copy only selected saved sessions. Original attachments are not needed or uploaded.
 sf=next(f for f in manifest['files'] if f['destination']=='sessions.json')
 data=(archive/sf['archiveName']).read_bytes();assert hashlib.sha256(data).hexdigest()==sf['sha256']
 envelope=json.loads(data);envelope={k:v for k,v in envelope.items() if k not in ['folders','preferences','topics','verifiedPairDecisions','careTeam','profile']}
 envelope['sessions']=[s for s in envelope['sessions'] if s['id'] in records.values()];assert len(envelope['sessions'])==5
 for s in envelope['sessions']:
  assert hashlib.sha256(s['transcript'].encode()).hexdigest()==mr[s['id']]['sourceTextSHA256']
  for k in ['summary','summaryEntries','summaryRun','summaryDrafts','summaryRevisions','extractionVersion']:s.pop(k,None)
 (out/'seed.json').write_text(json.dumps(envelope))
 code=out/'client';code.mkdir();files=['SpeechSessionApp/HealthSummaryModel.swift','SpeechSessionApp/SummaryContentRouting.swift','SpeechSessionApp/VisitSummaryModels.swift','SpeechSessionApp/PractitionerContactsFormatting.swift','SpeechSessionApp/GlobalSummaryModels.swift']
 for f in files:(code/Path(f).name).write_bytes(source('0e499b6',f))
 deployed=out/'deployment';backend=deployed/'vercel-openai-proxy';backend.mkdir(parents=True)
 paths=subprocess.check_output(['git','ls-tree','-r','--name-only','f7af55e','vercel-openai-proxy'],cwd=ROOT,text=True).splitlines()
 for f in paths:
  if '/api/' in f and '/api/_lib/' not in f:continue
  if '/tests/' in f or f.endswith('vercel.json'):continue
  target=deployed/f;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(source('f7af55e',f))
 scripts=backend/'scripts';scripts.mkdir(exist_ok=True)
 for f in ['benchmark-budget.ts','decisions-benchmark.ts']:(scripts/f).write_bytes((ROOT/'vercel-openai-proxy/scripts'/f).read_bytes())
 prefix='benchmark-speed-'+str(uuid.uuid4())+':';token=secrets.token_urlsafe(32)
 config={'prefix':prefix,'tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+86400)*1000)}
 (backend/'api/config.json').write_text(json.dumps(config));(backend/'api/benchmark.ts').write_bytes((Path(__file__).parent/'endpoint.ts').read_bytes())
 ledger=backend/'api/_lib/ledger.ts';s=ledger.read_text();s="import { assertExperimentAllowance, sharedLimit } from '../../scripts/benchmark-budget';\nconst experiment = require('../config.json');\n"+s
 marker='    const reserve = reservation(model, 6000);';assert s.count(marker)==1
 s=s.replace(marker,marker+"\n    if(BigInt(budget.limit_nusd)>sharedLimit)throw Error('budget_configuration_changed');\n    await assertExperimentAllowance(db,experiment.prefix,owner,reserve);")
 ledger.write_text(s)
 worker=backend/'api/_lib/worker.ts';w=worker.read_text().replace('  await cleanup();','  // Isolated diagnostics must not run global pilot cleanup.')
 w=w.replace('      const result = await client.responses.create(', '      const providerStarted = performance.now();\n      const result = await client.responses.create(')
 w=w.replace('      await settle(job.id, result.status', '      const providerSeconds = (performance.now()-providerStarted)/1000;\n      await settle(job.id, result.status')
 w=w.replace('result.usage ?? undefined, result.output_text, result.id);', '''result.usage ?? undefined, result.output_text, result.id);
      await database().query("UPDATE ai_payloads SET result=result || jsonb_build_object('providerSeconds',$2::double precision) WHERE job_id=$1 AND result IS NOT NULL",[job.id,providerSeconds]);''')
 worker.write_text(w)
 (backend/'vercel.json').write_text(json.dumps({'functions':{'api/benchmark.ts':{'maxDuration':120}}}))
 pkg=json.loads((backend/'package.json').read_text());pkg['scripts']['vercel-build']='tsc --noEmit';(backend/'package.json').write_text(json.dumps(pkg,indent=2))
 (deployed/'.vercel').mkdir();(deployed/'.vercel/project.json').write_text(json.dumps({'projectId':'prj_wR833xoPHsYwP53NgzB8jI6AwQq8','orgId':'team_fgJqPzyeJ33NrAcNqbTVtsiX','projectName':'speech-session-mvp'}))
 (out/'auth.json').write_text(json.dumps({'token':token}));(out/'auth.json').chmod(0o600)
 (out/'manifest.json').write_text(json.dumps({'clientCommit':'0e499b6','serverCommit':'f7af55e','keySHA256':sha(out/'key.json'),'seedSHA256':sha(out/'seed.json'),'records':records,'prefix':prefix,'experimentLimitUSD':1,'sharedLimitUSD':5,'sourceFiles':{f:sha(code/Path(f).name) for f in files}},indent=2))
 print('Frozen five source-verified records and key; diagnostic deployment prepared. No network calls.')
if __name__=='__main__':main()
