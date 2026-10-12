"""Replay identical failed extraction payloads. No key access and no production promotion."""
import hashlib,json,subprocess,sys,time
from pathlib import Path
from shadow import call
root=Path(sys.argv[1]).resolve();repo=Path(__file__).resolve().parents[2]
out=root/'replays';out.mkdir(exist_ok=False);rows=[]
validator="""const fs=require('fs');const Ajv=require(process.argv[1]);
const payload=JSON.parse(fs.readFileSync(process.argv[2]));const job=JSON.parse(fs.readFileSync(process.argv[3]));
const result=JSON.parse(job.result.output);const validate=new Ajv({strict:false}).compile(payload.response_format.json_schema.schema);
if(!validate(result))process.exit(1);
"""
try:
 for repeat,owner in enumerate(['controls-2','controls-3','controls-1'],1):
  for case in json.loads((root/'cases.json').read_text()):
   source=root/case['file'];assert hashlib.sha256(source.read_bytes()).hexdigest()==case['payloadSHA256']
   payload=json.loads(source.read_text());tag=f"{case['name']}-{repeat}";start=time.monotonic()
   submitted,_=call(root,{'action':'submit','run':owner,'payload':payload},out/(tag+'-submit'))
   assert not submitted.get('reused'), 'Replay must be fresh'
   job,_=call(root,{'action':'run','run':owner,'id':submitted['id']},out/tag)
   valid=False
   if job.get('state')=='completed':
    valid=subprocess.run(['node','-e',validator,str(repo/'vercel-openai-proxy/node_modules/ajv'),str(source),str(out/(tag+'.response.json'))],capture_output=True).returncode==0
   rows.append({'case':case['name'],'repeat':repeat,'state':job.get('state'),'schemaValid':valid,'elapsedSeconds':time.monotonic()-start,'inputTokens':job.get('input_tokens'),'outputTokens':job.get('output_tokens'),'costNUSD':job.get('cost_nusd'),'diagnostics':job.get('result',{}).get('diagnostics')})
   (out/'comparison.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows[-1]),flush=True)
   if not valid:raise RuntimeError('Extraction still fails; stop rather than retry automatically')
finally:
 (out/'comparison.json').write_text(json.dumps(rows,indent=2))
