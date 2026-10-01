"""Guard app call-site routing and execute its production response schemas offline."""
from pathlib import Path
import re
import subprocess
import tempfile
import plistlib

root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / 'SpeechSessionApp/Info.plist').read_bytes())
assert info['DurableAIProcessingEnabled'] is True
assert info['DurableConditionWorkflowsEnabled'] is True
source = (root / 'SpeechSessionApp/HealthSummaryModel.swift').read_text()
assert 'timingStage' not in source
assert r'expectedCheckIDs: batch.map(\.id)' in source
assert 'decodeKeyedChecks(object["decisions"]' in source
assert 'private func request(stage: String,' in source
assert 'force: true' not in source, 'Organize must not bypass accepted unchanged results'
processor = source.split('func synthesizeConditions(', 1)[1]
assert processor.index('store?.conditionSynthesis(for: facts)') < processor.index('beginJob(jobID)'), 'Reuse accepted results before starting inference'
assert '"condition-request-v2", stage, model, route, schema, instructions, input' in processor, 'Exact request cache must include the complete request contract'
routing = (root / 'SpeechSessionApp/OpenAIRouting.swift').read_text()
assert routing.index('var job = try await exchange(statusURL.url!, method: "GET")') < routing.index('while true'), 'Fetch saved result before handling a deduplicated completed submission'
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
    stop_tests = Path(directory) / 'StopTests.swift'
    stop_tests.write_text('''import Foundation
actor Counter {
 var value = 0
 func increment() { value += 1 }
}
@main struct StopTests {
 static func main() async throws {
  let stop = DurableProcessingStop(), counter = Counter()
  let completed = try await stop.register { await counter.increment() }
  await stop.completed(completed)
  _ = try await stop.register { await counter.increment() }
  // Foreground cancellation must not propagate to server work.
  let polling = Task { try await Task.sleep(for: .seconds(10)) }
  polling.cancel()
  let before = await counter.value
  assert(before == 0)
  try await stop.stop()
  let after = await counter.value
  assert(after == 1)
  do { _ = try await stop.register {}; fatalError("Stopped preparation accepted a new request") }
  catch is CancellationError {}
  try await stop.stop()
  let repeated = await counter.value
  assert(repeated == 1)
  print("Explicit Stop and background polling cancellation passed")
  for status in [400,401,402,403,404,405,413,503] {
   do {
    try OpenAIChatTransport.validateDurableResponse(data: Data("{\\"error\\":{\\"code\\":\\"pilot_disabled\\",\\"message\\":\\"private source text\\"}}".utf8), status: status)
    fatalError("Expected failure")
   } catch {
    assert(!error.localizedDescription.contains("private source text"))
    assert(error.localizedDescription != "The summary service is unavailable right now.")
   }
  }
  try OpenAIChatTransport.validateDurableResponse(data: Data(), status: 200)
  print("Durable endpoint configuration and safe actionable errors passed")
 }
}
''')
    executable = Path(directory) / 'stop-tests'
    subprocess.run(['swiftc', str(root / 'SpeechSessionApp/OpenAIRouting.swift'), str(stop_tests), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
