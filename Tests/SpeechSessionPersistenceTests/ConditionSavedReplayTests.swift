import XCTest
@testable import SpeechSessionPersistence

final class ConditionSavedReplayTests: XCTestCase {
    func testPrivateSavedResultContract() async throws {
        guard let path = ProcessInfo.processInfo.environment["CONDITION_PRIVATE_REPLAY"] else {
            throw XCTSkip("Local private replay path not supplied")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resultData = try JSONSerialization.data(withJSONObject: object["result"]!)
        let batches = object["entries"] as! [[[String: Any]]]
        let context = object["context"] as! [[String: Any]]
        let preserved = object["preserved"] as! [String: Any]
        let preservedRows = (preserved["unassigned"] as! [String]).map { ["id": $0] }
        let facts = try (batches.flatMap { $0 } + context + preservedRows).map { row -> HealthFact in
            var entry = SummaryEntry(category: .symptoms, title: "Synthetic replay occurrence " + (row["id"] as! String), details: "", origin: .userAdded)
            entry.id = try XCTUnwrap(UUID(uuidString: row["id"] as! String))
            return HealthFact(id: entry.id.uuidString, occurrences: [entry], preference: .init(id: entry.id.uuidString), topicIDs: [])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        try await store.upsert(Session(transcript: "Synthetic replay", summaryEntries: facts.flatMap(\.occurrences)))
        let current = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        let result = try JSONDecoder().decode(ConditionSynthesis.self, from: resultData)

        let keys = result.groups.map { ConditionSummaryProjection.conditionKey($0.name) + "|" + $0.bodySystem }
        XCTAssertEqual(Set(keys).count, keys.count, "Duplicate canonical headings")
        XCTAssertEqual(result.groups.filter { group in (group.entryReasons ?? [:]).contains { !group.entryIDs.contains($0.key) || $0.value.isEmpty || $0.value.count > 300 } }.count, 0, "Invalid per-entry reasons")
        XCTAssertNoThrow(try result.validate(facts))
        try await store.saveConditionSynthesis(result, expected: current)
        let reloaded = await store.conditionSynthesis(for: current)
        XCTAssertNotNil(reloaded, "Completed result must survive save and reload")
        let applied = result.applying(to: facts)
        XCTAssertEqual(Set(applied.flatMap(\.occurrences).map(\.id)), Set(facts.flatMap(\.occurrences).map(\.id)))
        let displayed = ConditionSummaryProjection.groups(facts: applied, topics: [])
        for group in result.groups {
            XCTAssertTrue(displayed.contains { ConditionSummaryProjection.conditionKey($0.name) == ConditionSummaryProjection.conditionKey(group.name) }, "Checked heading missing from display")
        }
    }
}
