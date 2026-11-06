#!/usr/bin/env python3
"""Fail closed on missing, provisional, or unbound release evidence. No model grading."""
import argparse,json,math,re
from pathlib import Path

def failures(e):
    bad=[]
    for key in ['sourceDigest','corpusSHA256','answerKeySHA256','appBuild','backendCommit']:
        if not isinstance(e.get(key),str) or not e[key]:bad.append('missing '+key)
    if e.get('answerKeyStatus')!='adjudicated':bad.append('answer key is not adjudicated')
    gates={'supportedPrecision':(.99,'min'),'materialRecall':(.95,'min'),'criticalErrors':(0,'max'),
           'namelessMedicationCards':(0,'max'),'duplicatePublications':(0,'max'),'typicalCompletionRate':(.99,'min'),
           'openHistoryP95Seconds':(1,'max'),'newRecordMedianSeconds':(30,'max'),'newRecordP95Seconds':(60,'max')}
    for key,(target,kind) in gates.items():
        value=e.get(key)
        if not isinstance(value,(int,float)) or isinstance(value,bool) or not math.isfinite(value) or value<0 or (key in ['supportedPrecision','materialRecall','typicalCompletionRate'] and value>1) or (value<target if kind=='min' else value>target):bad.append(key)
    for key in ['originalsPreserved','patientEditsPreserved','legacyReplayPassed','physicalDeviceRecoveryPassed','accessibilityPassed','sourceChangesPassed','databaseFaultsPassed']:
        if e.get(key) is not True:bad.append(key)
    if e.get('measuredUpdates',0)<100:bad.append('at least 100 measured updates required')
    return bad

def main():
    parser=argparse.ArgumentParser();parser.add_argument('evidence',type=Path);parser.add_argument('--manifest',type=Path,required=True);args=parser.parse_args()
    e=json.loads(args.evidence.read_text());m=json.loads(args.manifest.read_text());bad=failures(e)
    if e.get('backendBaseURL')!=m.get('backendBaseURL') or not m.get('backendBaseURL'):bad.append('backend URL mismatch')
    if e.get('features')!=m.get('features') or not isinstance(m.get('features'),dict):bad.append('runtime features mismatch')
    if not re.fullmatch(r'[0-9a-f]{40}',m.get('gitCommit','')):bad.append('missing app commit')
    if e.get('sourceDigest')!=m.get('sourceDigest') or e.get('appBuild')!=m.get('appBuild'):bad.append('manifest mismatch')
    if bad:raise SystemExit('Release blocked: '+', '.join(bad))
    print('Consumer release evidence passed for '+m['sourceDigest'])
if __name__=='__main__':main()
