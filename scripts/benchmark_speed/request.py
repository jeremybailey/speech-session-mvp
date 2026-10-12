"""Authenticated diagnostic transport. No credential or clinical output printed."""
import json,subprocess,sys,tempfile
from pathlib import Path
from transport_errors import error_message
root,request,output=[Path(x).resolve() for x in sys.argv[1:4]];auth=json.loads((root/'auth.json').read_text())
with tempfile.TemporaryDirectory(prefix='cc-speed-') as tmp:
 headers=Path(tmp)/'headers';headers.write_text('Authorization: Bearer '+auth['token']+'\nContent-Type: application/json\n');headers.chmod(0o600)
 cli=auth['cli']+['curl','/api/benchmark','--deployment',auth['deployment'],'--','--silent','--show-error','--request','POST','--header','@'+str(headers),'--data-binary','@'+str(request),'--output',str(output),'--max-time','125']
 result=subprocess.run(cli,cwd=root/'deployment',capture_output=True,timeout=145)
 if result.returncode == 0 and output.exists():
  try:
   raw = output.read_text()
   message = error_message(json.loads(raw))
  except (ValueError, UnicodeError):
   message = 'Benchmark transport returned invalid JSON; no automatic retry'
  if message:
   # Keep original response as local evidence, separate from the safe bridge error.
   output.replace(output.with_suffix('.transport-response.json'))
   output.write_text(json.dumps({'error': message}))
 sys.exit(result.returncode)
