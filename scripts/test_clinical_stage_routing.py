"""Guard app call-site routing and execute its production response schemas offline."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'SpeechSessionApp/HealthSummaryModel.swift').read_text()
assert 'timingStage' not in source
assert r'expectedCheckIDs: batch.map(\.id)' in source
assert 'decodeKeyedChecks(object["decisions"]' in source
assert 'private func request(stage: String,' in source
assert not re.search(r'\brequest\(system:', source)
for function, stage in [('auditBatch', 'checking'), ('classifyForStory', 'classification'),
                        ('boundedExtraction', 'extraction')]:
    body = source.split('private func ' + function + '(', 1)[1].split('\n    private func ', 1)[0]
    assert f'request(stage: "{stage}"' in body, function
checker = source.split('private func checkForStory(', 1)[1].split('/// Semantic candidates', 1)[0]
assert 'catch' not in checker, 'Technical checker failures must propagate to record recovery'
assert 'entries: allEntries + draft' not in source, 'Unchecked contacts must not enter checkpoints'
server = (root / 'vercel-openai-proxy/api/v1/health-processing/stages.ts').read_text()
allowed = server.split('const allowedStages = new Set([', 1)[1].split(']);', 1)[0]
for stage in re.findall(r'request\(stage: "([^"]+)"', source):
    assert f'"{stage}"' in allowed, stage
schema = (root / 'Sources/SpeechSessionPersistence/ClinicalResponseFormat.swift').read_text().split('public enum ClinicalResponseFormat', 1)[1]
program = '''import Foundation
enum SummaryEntryCategory: String, CaseIterable { case symptoms }
private enum ClinicalResponseFormat''' + schema + '''
func decision(_ stage: String) -> [String: Any] {
 let format = ClinicalResponseFormat.forStage(stage)
 let wrapper = format["json_schema"] as! [String: Any]
 let schema = wrapper["schema"] as! [String: Any]
 let properties = schema["properties"] as! [String: Any]
 let decisions = properties["decisions"] as! [String: Any]
 let items = decisions["items"] as! [String: Any]
 return items["properties"] as! [String: Any]
}
// Classification then verification, repeatedly: UUID checker IDs must never become integer category IDs.
for _ in 0..<10 {
 let classification = decision("classification")
 assert((classification["id"] as! [String: Any])["type"] as! String == "integer")
 let checking = decision("checking")
 assert((checking["id"] as! [String: Any])["type"] as! String == "string")
 assert(checking["supported"] != nil && checking["citations"] != nil)
 assert(checking["category"] == nil)
}
print("Clinical stage routing and schemas passed")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(program)
    subprocess.run(['swift', str(path)], check=True)
