from pathlib import Path
import argparse, os, subprocess
parser = argparse.ArgumentParser(description='Replay private frozen B outputs through the current native converter without inference.')
parser.add_argument('--fixtures', required=True, help='Private folder containing five */native-cache.json fixtures')
args = parser.parse_args()
p = Path(__file__).resolve().parents[1]
s=(p/'SpeechSessionApp/WholeHistoryBTrial.swift').read_text().split('struct WholeHistoryBTrialView: View')[0]
s=s.replace('import SpeechSessionPersistence','@testable import SpeechSessionPersistence\nimport XCTest')
s+='''
struct OpenAIChatTransport {
    var durableJobsURL: URL? { nil }
    func makeAuthorizationHeader() async throws -> String { throw URLError(.unsupportedURL) }
}
extension BTrialModel {
    func restoreFixture(_ url: URL) throws {
        saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        state = saved["state"] as? String ?? "completed"
        records = (saved["records"] as! [[String: Any]]).map { Session(id: UUID(uuidString: $0["id"] as! String)!, transcript: $0["text"] as! String) }
        try decode(saved["output"] as! String)
        narrativeState = narrativeJob["state"] as? String ?? "completed"
        try decodeNarrative(narrativeJob["output"] as! String)
    }
}
final class WholeHistoryNativeReplayTests: XCTestCase {
    @MainActor func testFiveFrozenResultsPublishWithoutFactLoss() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WHOLE_HISTORY_REPLAY_ROOT"]!)
        let cases = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("native-cache.json").path) }
        XCTAssertEqual(cases.count, 5)
        for folder in cases {
            let model = BTrialModel()
            try model.restoreFixture(folder.appendingPathComponent("native-cache.json"))
            let publication = try model.publication()
            XCTAssertEqual(publication.entries.values.reduce(0) { $0 + $1.count }, model.facts.count)
            for session in model.records {
                for entry in publication.entries[session.id]! {
                    XCTAssertTrue(SummaryVerification.isPortraitEligible(entry, source: session.transcript), folder.lastPathComponent + ": " + entry.category.rawValue)
                }
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = try SessionStore(storageDirectory: dir)
            try await store.save(model.records)
            try await store.publishWholeHistory(publication, expected: model.records)
            let snapshot = try await store.healthSnapshot()
            let facts = HealthMemoryProjection.facts(in: snapshot)
            let groups = ConditionSummaryProjection.groups(facts: facts, topics: snapshot.topics)
            for concern in model.concerns {
                XCTAssertTrue(groups.contains { $0.name == concern.name }, folder.lastPathComponent + ": missing concern")
            }
        }
    }
}
'''
target = p / 'Tests/SpeechSessionPersistenceTests/WholeHistoryNativeReplayTests.swift'
if target.exists():
    raise SystemExit('Replay test already exists; preserve it before running this helper.')
try:
    target.write_text(s)
    env = dict(os.environ, WHOLE_HISTORY_REPLAY_ROOT=str(Path(args.fixtures).resolve()))
    result = subprocess.run(['swift', 'test', '--filter', 'WholeHistoryNativeReplayTests'], cwd=p, env=env)
finally:
    target.unlink(missing_ok=True)
raise SystemExit(result.returncode)
