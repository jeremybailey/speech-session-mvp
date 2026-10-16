"""Offline checks for the production durable wait and explicit-stop behavior."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    source = path / 'WaitTests.swift'
    source.write_text('import Foundation\nimport CryptoKit\nactor Counter {\n var value = 0\n func increment() { value += 1 }\n}\n@main struct StopTests {\n static func main() async throws {\n  let payload: [String: Any] = ["version": 1, "batches": [["id": "synthetic", "text": "unchanged"]]]\n  let legacy = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])\n  let revised = try DurableRequestIdentity.body(payload, conditionWorkflow: true)\n  let repeatedBody = try DurableRequestIdentity.body(payload, conditionWorkflow: true)\n  let ordinary = try DurableRequestIdentity.body(payload, conditionWorkflow: false)\n  assert(revised != legacy && repeatedBody == revised && ordinary == legacy)\n  assert(SHA256.hash(data: revised) != SHA256.hash(data: legacy))\n  assert(payload["clientRevision"] == nil)\n  var decoded = try JSONSerialization.jsonObject(with: revised) as! [String: Any]\n  assert(decoded.removeValue(forKey: "clientRevision") as? String == "condition-exact-heading-v2")\n  let restored = try JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys])\n  assert(restored == legacy)\n  print("Repaired workflow bodies and upload digests differ; identical retries and ordinary requests remain stable")\n  let start = Date(timeIntervalSince1970: 1000)\n  let wait = DurableProcessingWait(conditionWorkflow: false, now: start)\n  try wait.check(state: "queued", now: start.addingTimeInterval(299))\n  for state in ["queued", "running"] {\n   do { try wait.check(state: state, now: start.addingTimeInterval(300)); fatalError("Unbounded wait") }\n   catch { assert((error as NSError).code == 408) }\n  }\n  // A completed job must still be readable after resuming from background.\n  try wait.check(state: "completed", now: start.addingTimeInterval(2700))\n  let workflow = DurableProcessingWait(conditionWorkflow: true, now: start)\n  try workflow.check(state: "running", now: start.addingTimeInterval(1799))\n  do { try workflow.check(state: "running", now: start.addingTimeInterval(1800)); fatalError("Unbounded workflow") }\n  catch { assert((error as NSError).code == 408) }\n  print("Queued/running wait deadlines and completed background results passed")\n  let stop = DurableProcessingStop(), counter = Counter()\n  let completed = try await stop.register { await counter.increment() }\n  await stop.completed(completed)\n  _ = try await stop.register { await counter.increment() }\n  // Foreground cancellation must not propagate to server work.\n  let polling = Task { try await Task.sleep(for: .seconds(10)) }\n  polling.cancel()\n  let before = await counter.value\n  assert(before == 0)\n  try await stop.stop()\n  let after = await counter.value\n  assert(after == 1)\n  do { _ = try await stop.register {}; fatalError("Stopped preparation accepted a new request") }\n  catch is CancellationError {}\n  try await stop.stop()\n  let repeated = await counter.value\n  assert(repeated == 1)\n  print("Explicit Stop and background polling cancellation passed")\n  for status in [400,401,402,403,404,405,413,503] {\n   do {\n    try OpenAIChatTransport.validateDurableResponse(data: Data("{\\"error\\":{\\"code\\":\\"pilot_disabled\\",\\"message\\":\\"private source text\\"}}".utf8), status: status)\n    fatalError("Expected failure")\n   } catch {\n    assert(!error.localizedDescription.contains("private source text"))\n    assert(error.localizedDescription != "The summary service is unavailable right now.")\n   }\n  }\n  try OpenAIChatTransport.validateDurableResponse(data: Data(), status: 200)\n  print("Durable endpoint configuration and safe actionable errors passed")\n }\n}\n')
    source.write_text(source.read_text().replace('  let start = Date(timeIntervalSince1970: 1000)', r"""
  let deferred = try DurableResultReceipt.validateAcknowledgment(data: Data(), status: 405, jobID: "job")
  assert(!deferred)
  let confirmed = try DurableResultReceipt.validateAcknowledgment(data: Data(#"{"id":"job","received":true}"#.utf8), status: 200, jobID: "job")
  assert(confirmed)
  for (status, body) in [(200, "{}"), (200, #"{"id":"other","received":true}"#), (200, "not JSON"), (401, "{}"), (409, "{}"), (503, "{}")] {
    do {
      _ = try DurableResultReceipt.validateAcknowledgment(data: Data(body.utf8), status: status, jobID: "job")
      fatalError("Invalid receipt accepted")
    } catch {}
  }
  print("Legacy receipt deferral, valid acknowledgment, wrong identities, malformed responses and server failures passed")
  func token(_ subject: String) throws -> String {
    let claims = try JSONSerialization.data(withJSONObject: ["iss": "https://synthetic.invalid", "sub": subject])
    let encoded = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "Bearer header." + encoded + ".signature"
  }
  let route = URL(string: "https://synthetic.invalid/jobs")!
  let key = try DurableResultReceipt.key(body: ordinary, url: route, authorization: token("alice"), experimental: false)
  let otherKey = try DurableResultReceipt.key(body: ordinary, url: route, authorization: token("bob"), experimental: false)
  assert(key != otherKey)
  let experimentKey = try DurableResultReceipt.key(body: ordinary, url: route, authorization: token("alice"), experimental: true)
  assert(key != experimentKey)
  let receiptRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: receiptRoot) }
  let missingReceipt = try DurableResultReceipt.load(key: key, directory: receiptRoot)
  assert(missingReceipt == nil)
  let receipt = DurableResultReceipt(jobID: "synthetic-job", output: "Complete synthetic result", expiresAt: Date().addingTimeInterval(60))
  try receipt.save(key: key, directory: receiptRoot)
  let restoredReceipt = try DurableResultReceipt.load(key: key, directory: receiptRoot)
  assert(restoredReceipt?.output == receipt.output && restoredReceipt?.jobID == receipt.jobID)
  let expired = DurableResultReceipt(jobID: "synthetic-job", output: "Old synthetic result", expiresAt: Date(timeIntervalSince1970: 0))
  try expired.save(key: key, directory: receiptRoot)
  let expiredReceipt = try DurableResultReceipt.load(key: key, directory: receiptRoot)
  assert(expiredReceipt == nil)
  print("Durable local receipt persistence, account isolation, experiment isolation and expiry passed")
  let start = Date(timeIntervalSince1970: 1000)
"""))
    executable = path / 'wait-tests'
    subprocess.run(['swiftc', '-module-cache-path', str(path / 'module-cache'), str(root / 'SpeechSessionApp/OpenAIRouting.swift'), str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
