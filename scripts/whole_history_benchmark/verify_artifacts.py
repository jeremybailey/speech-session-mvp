"""Verify immutable processing evidence, explicit tool amendments and cleanup."""
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve();frozen=json.loads((root/'freeze.json').read_text());cleanup=json.loads((root/'cleanup-attestation.json').read_text())
amendments={}
for name in ['scoring-amendment.json','run-reporting-amendment.json']:
 if not (root/name).exists():continue
 a=json.loads((root/name).read_text());assert frozen['files'][a['file']]==a['originalSHA256'];amendments[a['file']]=a['updatedSHA256']
removed={x['path']:x['sha256'] for x in cleanup['temporaryAccessFilesRemoved']};verified=0
for name,expected in frozen['files'].items():
 path=Path(name) if name.startswith('/') else root/name
 if name in amendments:expected=amendments[name]
 if not path.exists():assert removed.get(name)==expected,'Missing frozen file without cleanup evidence: '+name
 else:assert hashlib.sha256(path.read_bytes()).hexdigest()==expected,'Changed frozen evidence: '+name
 verified+=1
assert cleanup['remotePayloads']=={'job_payloads':0,'workflow_payloads':0,'upload_parts':0}
assert cleanup['pilotAliasesUnchanged'] and cleanup['accountingRetained'] and cleanup['unresolvedChargesRetained']
if (root/'original-checkouts-audit.json').exists():
 for x in json.loads((root/'original-checkouts-audit.json').read_text()):assert not x['changedOriginalFiles']
assert not (root/'auth.json').exists()
print(f'{verified} frozen file bindings verified, with any explicit amendments and documented access-file removal; original checkouts and pilot aliases unchanged.')
