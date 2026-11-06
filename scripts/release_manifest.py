#!/usr/bin/env python3
"""Emit nonclinical release evidence; --check compares the complete source tree identity."""
import argparse,hashlib,json,subprocess,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def manifest(build):
    paths=[ROOT/p for p in ['Package.swift','SpeechSessionApp.xcodeproj/project.pbxproj','scripts/release_manifest.py','scripts/build_resilience_device.py','scripts/package_isolated_backend.py','scripts/isolated-router-smoke.ts','vercel-openai-proxy/package.json','vercel-openai-proxy/package-lock.json','vercel-openai-proxy/vercel.json']]
    for folder in ['Sources','SpeechSessionApp','vercel-openai-proxy/api','vercel-openai-proxy/migrations']:
        paths += [p for p in (ROOT/folder).rglob('*') if p.is_file() and p.suffix in {'.swift','.ts','.sql','.json','.plist'} and not p.name.endswith('.local.json')]
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
    try: commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True,stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError: commit=os.environ.get('CC_RELEASE_COMMIT','unavailable-in-build-sandbox')
    return {'format':1,'backendBaseURL':os.environ.get('CC_BACKEND_BASE_URL','https://speech-session-mvp.vercel.app/api'),'features':{'incremental':os.environ.get('CC_INCREMENTAL_RECORDS_ENABLED','NO')=='YES','sqlite':os.environ.get('CC_SQLITE_ENABLED','NO')=='YES'},'appBuild':build,'gitCommit':commit,
      'sourceDigest':hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest(),'files':hashes,
      'model':'gpt-6-luna','reasoning':'medium','contract':'incremental-records-v1','validator':'incremental-validator-v3','serverMigration':10,'localMigration':1}
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--build',required=True);parser.add_argument('--check',type=Path);parser.add_argument('--compact',action='store_true');args=parser.parse_args();value=manifest(args.build)
    if args.compact:value.pop('files')
    if args.check:
        assert json.loads(args.check.read_text())==value,'Release source differs from evaluated manifest'
    else: print(json.dumps(value,indent=2,sort_keys=True))
if __name__=='__main__':main()
