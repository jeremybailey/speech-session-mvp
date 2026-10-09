import XCTest
import CryptoKit
@testable import SpeechSessionPersistence

/// Opt-in, read-only replay of a user's export through the real presentation code.
/// No patient fixture is checked in, and this does not call an inference service.
final class ScorecardSnapshotTests: XCTestCase {
    func testExportSavedProjection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let archivePath = env["SCORECARD_ARCHIVE"], let outputPath = env["SCORECARD_OUTPUT"],
              let record = env["SCORECARD_RECORD_ID"], let recordID = UUID(uuidString: record) else {
            throw XCTSkip("Set SCORECARD_ARCHIVE, SCORECARD_OUTPUT and SCORECARD_RECORD_ID for private snapshot replay.")
        }
        let archive = URL(fileURLWithPath: archivePath)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DataTransferManifest.self, from: Data(contentsOf: archive.appendingPathComponent("manifest.json")))
        let selected = try XCTUnwrap(manifest.records.first { $0.id == recordID })
        let sourceData = try Data(contentsOf: archive.appendingPathComponent(selected.sourceTextFile))
        XCTAssertEqual(SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined(), selected.sourceTextSHA256)
        let isolated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolated) }
        // Restore only metadata into an isolated store; originals are never modified.
        for name in [SessionStore.sessionsFileName, "condition-synthesis.json"] {
            guard let file = manifest.files.first(where: { $0.destination == name }) else { continue }
            let data = try Data(contentsOf: archive.appendingPathComponent(file.archiveName))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), file.sha256)
            try data.write(to: isolated.appendingPathComponent(name))
        }
        let store = try SessionStore(storageDirectory: isolated)
        let snapshot = try await store.healthSnapshot()
        let session = try XCTUnwrap(snapshot.sessions.first { $0.id == recordID })
        XCTAssertEqual(Data(session.transcript.utf8), sourceData)
        let allFacts = HealthMemoryProjection.facts(in: snapshot, verifiedOnly: true)
        let displayed = await store.displayedConditionFacts(for: allFacts)
        let conditions = ConditionSummaryProjection.groups(facts: displayed, topics: snapshot.topics)
        let visibleIDs = Set(allFacts.flatMap(\.occurrences).map(\.id))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let entries = try (session.summaryEntries ?? []).map { entry -> [String: Any] in
            var row = try JSONSerialization.jsonObject(with: encoder.encode(entry)) as! [String: Any]
            row["accepted"] = SummaryVerification.isVisible(entry, source: session.transcript)
            row["visible"] = visibleIDs.contains(entry.id)
            row["displayDetails"] = HealthDetailPresentation.remainingDetails(entry)
            row["displayFields"] = try JSONSerialization.jsonObject(with: encoder.encode(HealthDetailPresentation.fields(entry)))
            row["conditions"] = conditions.filter { !$0.isUncategorized && $0.facts.flatMap(\.occurrences).contains { $0.id == entry.id } }.map {
                ["name": $0.name, "bodySystem": $0.bodySystem, "appSection": HealthAreaKind.classify($0).title]
            }
            return row
        }
        let output: [String: Any] = ["recordID": record, "sourceSHA256": selected.sourceTextSHA256,
            "exportID": manifest.exportID.uuidString, "appVersion": manifest.appVersion,
            "mode": "saved-output-local-projection", "paidRequests": 0, "entries": entries]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        let visibleCount = entries.filter { $0["visible"] as? Bool == true }.count
        print("Private snapshot exported: \(entries.count) entries, \(visibleCount) visible. No inference requests.")
    }
}
