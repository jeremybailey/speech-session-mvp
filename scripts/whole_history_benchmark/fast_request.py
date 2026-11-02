"""Same authenticated diagnostic route. Retry only a positively identified gateway 401/403;
no model work reached that endpoint. All retries preserve the exact request file and owner.
Never retry unknown responses or network timeouts here; preserve accounting uncertainty.
"""
import json,subprocess,sys,time
from pathlib import Path
root,request,output=[Path(x).resolve() for x in sys.argv[1:4]]
helper=Path(__file__).with_name('request.py')
for attempt in range(3):
 result=subprocess.run([sys.executable,str(helper),str(root),str(request),str(output)])
 raw=output.with_suffix('.transport-response.json')
 rejected=False
 if result.returncode==0 and raw.exists():
  try:
   body=json.loads(raw.read_text());error=body.get('error')
   rejected=isinstance(error,dict) and str(error.get('code')) in ['401','403'] and isinstance(body.get('protection'),dict)
  except (ValueError,AttributeError):pass
 if not rejected or attempt==2:sys.exit(result.returncode)
 raw.rename(output.with_suffix('.gateway-rejection-'+str(attempt)+'.json'))
 output.unlink(missing_ok=True)
 time.sleep(attempt+1)
