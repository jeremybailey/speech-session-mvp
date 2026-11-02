"""Controlled cold replay. Paid dispatch requires a frozen manifest and passing gates."""
import hashlib,json,os,subprocess,sys,time,uuid
from pathlib import Path
from contracts import payload,validate
ROOT=Path(__file__).resolve().parents[2]; HELPER=ROOT/'scripts/whole_history_benchmark/fast_request.py'
def write(path,value):path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n');path.chmod(0o600)
def request(root,run,body,trace):
    trace.mkdir(parents=True,exist_ok=True);tag=str(uuid.uuid4());body=dict(body,run=run)
    sent=trace/(tag+'.send.json');received=trace/(tag+'.receive.json');write(sent,body);t=time.monotonic()
    p=subprocess.run([sys.executable,str(HELPER),str(root),str(sent),str(received)],capture_output=True)
    write(trace/(tag+'.transport.json'),{'action':body['action'],'elapsedSeconds':time.monotonic()-t,'exitCode':p.returncode})
    if p.returncode or not received.exists():raise RuntimeError('transport_uncertain_no_retry')
    result=json.loads(received.read_text())
    if 'error' in result:raise RuntimeError(str(result['error']))
    return result

def candidate(root,run,records,proposal=None):
    out=root/run;out.mkdir(exist_ok=False);trace=out/'trace';start=time.monotonic();report={'run':run,'completed':False,'clinicallyVerified':False}
    try:
        p,preflight=payload(records,proposal);write(out/'preflight.json',preflight);write(out/'request.json',p)
        job=request(root,run,{'action':'submit','payload':p},trace);jid=job['id'];report['jobID']=jid
        job=request(root,run,{'action':'job','id':jid},trace)
        deadline=time.monotonic()+420
        while job['state'] in ('queued','running'):
            if time.monotonic()>deadline:raise RuntimeError('waiting_limit_no_redispatch')
            if job['state']=='running':time.sleep(1)
            job=request(root,run,{'action':'run' if job['state']=='queued' else 'job','id':jid},trace);write(out/'receipt.json',job)
        report['providerState']=job['state']
        raw=(job.get('result') or {}).get('output');report['hasOutput']=bool(raw)
        if job['state']!='completed' or not raw:raise RuntimeError('provider_'+job['state'])
        (out/'raw-output.txt').write_text(raw)
        output=json.loads(raw);write(out/'output.json',output)
        validate(output,records);report['completed']=True
    except Exception as e:report['failure']=str(e)
    report['elapsedSeconds']=time.monotonic()-start
    write(out/'run.json',report)
    write(out/'ledger.json',request(root,run,{'action':'status'},trace))
    print(run+': '+('complete' if report['completed'] else 'failed: '+report.get('failure','unknown')),flush=True)
    return report

def verify_frozen(root):
    lock=json.loads((root/'freeze.json').read_text())
    for name,expected in lock['files'].items():
        path=Path(name) if name.startswith('/') else root/name
        assert hashlib.sha256(path.read_bytes()).hexdigest()==expected,'Frozen source changed: '+name
    assert lock['syntheticTestsPassed'] and lock['combinedBuildPassed'] and lock['combinedTestsPassed']

def main(root):
    verify_frozen(root)
    records=json.loads((root/'records.json').read_text())['records'];results=[]
    for repetition in range(1,4):
        order=['A','B','C'] if repetition!=2 else ['B','C','A'];row={}
        for arm in order:
            if arm=='A':
                run='baseline-'+str(repetition);env=dict(os.environ,BENCHMARK_REQUEST_HELPER=str(HELPER),BENCHMARK_RUN_ID=str(uuid.uuid4()))
                p=subprocess.run([str(root/'harness/baseline-replay'),str(root),run],env=env,capture_output=True,text=True)
                (root/(run+'.log')).write_text(p.stdout+p.stderr)
                row['A']=json.loads((root/run/'run.json').read_text()) if (root/run/'run.json').exists() else {'completed':False,'failure':'baseline_process_failed'}
                print(run+': '+('complete' if row['A']['completed'] else 'failed; see private report'),flush=True)
            elif arm=='B':row['B']=candidate(root,'single-'+str(repetition),records)
            else:
                b=root/('single-'+str(repetition));output=b/'output.json'
                if output.exists():row['C']=candidate(root,'check-'+str(repetition),records,json.loads(output.read_text()))
                else:
                    row['C']={'completed':False,'failure':'B has no complete parsed output; no checking dispatch'}
                    (root/('check-'+str(repetition))).mkdir();write(root/('check-'+str(repetition))/'run.json',row['C'])
        results.append(row);write(root/'comparisons.json',results)
        status=request(root,'baseline-'+str(repetition),{'action':'status'},root/'status-trace');write(root/'latest-accounting.json',status)
        committed=int(status['experimentAccounting']['committed_nusd'])
        if not all(r.get('completed') for r in row.values()) or committed+1_000_000_000>5_000_000_000:break
if __name__=='__main__':main(Path(sys.argv[1]).resolve())
