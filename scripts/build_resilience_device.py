#!/usr/bin/env python3
"""Build a local device-test candidate; never install, upload, or change backend settings."""
import argparse,subprocess,plistlib
from urllib.parse import urlparse
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--base-url',required=True);p.add_argument('--build',type=int,required=True);p.add_argument('--derived-data',type=Path,required=True);p.add_argument('--sqlite',action='store_true');p.add_argument('--unsigned',action='store_true');p.add_argument('--simulator',action='store_true');a=p.parse_args()
assert a.build>0
endpoint=urlparse(a.base_url)
assert endpoint.scheme=='https' and endpoint.hostname and not endpoint.username and not endpoint.password and endpoint.path=='/api' and not endpoint.query and not endpoint.fragment
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
args=['xcodebuild','-project','SpeechSessionApp.xcodeproj','-scheme','Whole-history B Phone','-destination','generic/platform=iOS Simulator' if a.simulator else 'generic/platform=iOS','-derivedDataPath',str(a.derived_data),'CC_INCREMENTAL_RECORDS_ENABLED=YES','CC_SQLITE_ENABLED='+('YES' if a.sqlite else 'NO'),'CC_RELEASE_COMMIT='+commit,'CC_BACKEND_BASE_URL='+a.base_url,'CURRENT_PROJECT_VERSION='+str(a.build)]
if a.unsigned:args+=['CODE_SIGNING_ALLOWED=NO']
subprocess.run(args+['build'],cwd=root,check=True)
product=a.derived_data/'Build/Products'/('Debug-iphonesimulator' if a.simulator else 'Debug-iphoneos')/'SpeechSessionApp.app'
with (product/'Info.plist').open('rb') as f:info=plistlib.load(f)
assert info['CFBundleVersion']==str(a.build)
assert info['CloudOpenAIBaseURL']==a.base_url
assert info['IncrementalRecordsEnabled']=='YES'
assert info['TransactionalRecordStorageEnabled']==('YES' if a.sqlite else 'NO')
print('Verified device-test candidate:',product)
print('Backend migration 010 and incremental queue/recovery must be enabled in the test environment before inference tests.')
