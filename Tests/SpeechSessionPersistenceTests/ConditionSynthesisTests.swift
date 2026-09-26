import XCTest
@testable import SpeechSessionPersistence

final class ConditionSynthesisTests: XCTestCase {
    private func fact(_ title: String, category: SummaryEntryCategory = .symptoms) -> HealthFact {
        let entry = SummaryEntry(category: category, title: title, origin: .userAdded)
        return HealthFact(id: entry.id.uuidString, occurrences: [entry], preference: .init(id: entry.id.uuidString), topicIDs: [])
    }
    private func synthesis(_ facts: [HealthFact], name: String = "Ongoing eye concern") -> ConditionSynthesis {
        .init(groups: [.init(name: name, bodySystem: "eye", isPrimary: true, reason: "The patient describes these as one ongoing concern.", entryIDs: facts.flatMap(\.occurrences).map(\.id))], unassigned: [])
    }
    func testWholeHistoryGroupingKeepsSymptomsHistoryAndSourceIdentity() throws {
        let facts = [fact("Historical retinal surgery", category: .findings), fact("Impaired vision improving"), fact("Eye treatment", category: .medications)]
        let result = synthesis(facts)
        try result.validate(facts)
        let projected = result.applying(to: facts)
        let groups = ConditionSummaryProjection.groups(facts: projected, topics: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Ongoing eye concern")
        XCTAssertEqual(groups.first?.bodySystem, "eye")
        XCTAssertEqual(projected.flatMap(\.occurrences).map(\.title), facts.flatMap(\.occurrences).map(\.title))
        XCTAssertEqual(projected.flatMap(\.occurrences).map(\.id), facts.flatMap(\.occurrences).map(\.id))
        XCTAssertEqual(projected.flatMap(\.occurrences).map(\.clinicalStatus), facts.flatMap(\.occurrences).map(\.clinicalStatus))
    }
    func testUnassignedCannotResurfaceAsAutomaticCondition() throws {
        let facts = [fact("Abstract discussion")]
        let result = ConditionSynthesis(groups: [], unassigned: [facts[0].latest.id])
        try result.validate(facts)
        let groups = ConditionSummaryProjection.groups(facts: result.applying(to: facts), topics: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isUncategorized)
        XCTAssertEqual(groups[0].facts.count, 1)
    }
    func testBrokenLinksAndDuplicateGroupsFailWithoutPartialApplication() {
        let facts = [fact("Concern")]
        var result = synthesis(facts)
        result.unassigned = [facts[0].latest.id]
        XCTAssertThrowsError(try result.validate(facts))
        XCTAssertNil(result.applying(to: facts)[0].latest.evidence?.conditionGroup)
        result = synthesis(facts); result.groups[0].entryIDs = [UUID()]
        XCTAssertThrowsError(try result.validate(facts))
        result = synthesis(facts); result.groups[0].name = "Heart findings"
        XCTAssertThrowsError(try result.validate(facts))
        result = .init(groups: [], unassigned: [])
        XCTAssertThrowsError(try result.validate(facts))
    }
    func testManualAssignmentAndUnassignedChoiceWin() {
        var fact = fact("Concern")
        fact.preference.topicIDs = []
        let projected = synthesis([fact]).applying(to: [fact])
        XCTAssertNil(projected[0].latest.evidence?.conditionGroup)
        XCTAssertTrue(ConditionSummaryProjection.groups(facts: projected, topics: []).first!.isUncategorized)
    }
    func testFingerprintTracksEditsAndPatientAssignmentButNotOrdering() {
        let facts = [fact("First"), fact("Second")]
        XCTAssertEqual(ConditionSynthesis.fingerprint(facts), ConditionSynthesis.fingerprint(facts.reversed()))
        var changed = facts
        changed[0].preference.topicIDs = []
        XCTAssertNotEqual(ConditionSynthesis.fingerprint(facts), ConditionSynthesis.fingerprint(changed))
        changed = facts; changed[0].occurrences[0].details = "An edited detail"
        XCTAssertNotEqual(ConditionSynthesis.fingerprint(facts), ConditionSynthesis.fingerprint(changed))
    }
    func testCacheSurvivesReloadAndRejectsConcurrentEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let entry = SummaryEntry(category: .symptoms, title: "Eye concern", origin: .userAdded)
        var session = Session(transcript: "Synthetic source", summaryEntries: [entry])
        try await store.upsert(session)
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        try await store.saveConditionSynthesis(synthesis(facts), expected: facts)
        let reopened = try SessionStore(storageDirectory: directory)
        let cached = await reopened.conditionSynthesis(for: facts)
        XCTAssertEqual(cached?.groups.first?.name, "Ongoing eye concern")
        session.summaryEntries?[0].details = "Changed while the model was working"
        try await store.upsert(session)
        do {
            try await store.saveConditionSynthesis(synthesis(facts), expected: facts)
            XCTFail("Stale synthesis must not overwrite edited history")
        } catch { }
        let next = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        let stale = await store.conditionSynthesis(for: next)
        XCTAssertNil(stale)
    }
    func testDisplayRetainsOnlyUnchangedOrganizedEntriesAcrossReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let entry = SummaryEntry(category: .symptoms, title: "Eye concern", origin: .userAdded)
        try await store.upsert(Session(transcript: "Synthetic", summaryEntries: [entry]))
        let original = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        let initial = await store.displayedConditionFacts(for: original)
        XCTAssertTrue(initial.allSatisfy { $0.latest.evidence?.conditionSynthesisUnassigned == true })
        try await store.saveConditionSynthesis(synthesis(original), expected: original)
        let reopened = try SessionStore(storageDirectory: directory)
        let expanded = original + [fact("New provisional symptom")]
        let displayed = await reopened.displayedConditionFacts(for: expanded)
        XCTAssertEqual(displayed[0].latest.evidence?.conditionGroup, "Ongoing eye concern")
        XCTAssertTrue(displayed[1].latest.evidence?.conditionSynthesisUnassigned == true)
        var edited = original
        edited[0].occurrences[0].title = "Changed concern"
        let changed = await reopened.displayedConditionFacts(for: edited)
        XCTAssertTrue(changed[0].latest.evidence?.conditionSynthesisUnassigned == true)
        let removed = await reopened.displayedConditionFacts(for: [])
        XCTAssertTrue(removed.isEmpty)
    }

    func testLargeHistoryBatchesAndReconcilesWithoutDroppingOccurrences() async throws {
        var facts = (0..<140).map { fact("Repeated migraine \($0)") }
        for index in facts.indices { facts[index].occurrences[0].details = String(repeating: "Synthetic history. ", count: 220) }
        XCTAssertThrowsError(try ConditionSynthesis.input(facts))
        let portions = try ConditionSynthesis.batches(facts)
        XCTAssertGreaterThan(portions.count, 1)
        XCTAssertTrue(try portions.allSatisfy { try ConditionSynthesis.input($0).utf8.count <= 60_000 })
        let result = try await ConditionSynthesis.organize(facts: facts) { input in
            let json = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
            let entries = json["entries"] as! [[String: Any]]
            let ids = entries.map { UUID(uuidString: $0["id"] as! String)! }
            let response = ConditionSynthesis(groups: [.init(name: "Migraine", bodySystem: "neurological", isPrimary: false,
                reason: "Repeated mentions of the same concern", entryIDs: ids)], unassigned: [])
            return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        }
        try result.validate(facts)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].entryIDs), Set(facts.flatMap(\.occurrences).map(\.id)))
    }

    func testBatchingSplitsLargeOccurrenceHistoryWithinOneFact() throws {
        var combined = fact("Migraine")
        combined.occurrences = (0..<130).map { _ in SummaryEntry(category: .symptoms, title: "Migraine", origin: .userAdded) }
        let portions = try ConditionSynthesis.batches([combined])
        XCTAssertEqual(portions.count, 3)
        XCTAssertEqual(portions.flatMap { $0 }.flatMap(\.occurrences).count, 130)
    }

    func testBatchFailureNeverReturnsPartialOrganization() async throws {
        let facts = (0..<65).map { fact("Concern \($0)") }
        do {
            _ = try await ConditionSynthesis.organize(facts: facts) { _ in "{\"groups\":[],\"unassigned\":[]}" }
            XCTFail("Incomplete coverage must fail before saving")
        } catch { XCTAssertTrue(error is ConditionSynthesis.SynthesisError) }
    }

    func testResponseRecoveryKeepsValidGroupsAndIsolatesConflicts() throws {
        let facts = [fact("Eye concern"), fact("Migraine"), fact("Knee concern"), fact("Omitted")]
        let ids = facts.map { $0.latest.id }
        let raw = ConditionSynthesis(groups: [
            .init(name: "Eye concern", bodySystem: " Eye ", isPrimary: true, reason: String(repeating: "Detail ", count: 60), entryIDs: [ids[0], ids[0], UUID()]),
            .init(name: "Eye concern", bodySystem: "eye", isPrimary: true, reason: "Same concern", entryIDs: [ids[0]]),
            .init(name: "Migraine", bodySystem: "neurological", isPrimary: true, reason: "Concern", entryIDs: [ids[1], ids[2]]),
            .init(name: "Knee concern", bodySystem: "musculoskeletal", isPrimary: false, reason: "Concern", entryIDs: [ids[2]])
        ], unassigned: [ids[0]])
        let recovered = try ConditionSynthesis.normalizedResponse(String(decoding: JSONEncoder().encode(raw), as: UTF8.self), facts: facts)
        try recovered.result.validate(facts)
        XCTAssertEqual(recovered.result.groups.count, 2)
        XCTAssertEqual(recovered.unresolved, Set([ids[2], ids[3]]))
        XCTAssertTrue(recovered.result.groups.allSatisfy { !$0.isPrimary && $0.reason.count <= 300 })
    }

    func testMissingEntriesAreRetriedWithoutRepeatingSuccessfulEntries() async throws {
        let facts = [fact("Eye concern"), fact("Migraine")]
        let first = facts[0].latest.id
        actor Calls {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let calls = Calls()
        let result = try await ConditionSynthesis.organize(facts: facts) { input in
            let count = await calls.next()
            if count == 2 {
                XCTAssertFalse(input.contains(first.uuidString))
                XCTAssertTrue(input.contains(facts[1].latest.id.uuidString))
            }
            let group = ConditionSynthesis.Group(name: count == 1 ? "Eye concern" : "Migraine",
                bodySystem: count == 1 ? "eye" : "neurological", isPrimary: false, reason: "Explicit concern",
                entryIDs: [count == 1 ? first : facts[1].latest.id])
            return String(decoding: try JSONEncoder().encode(ConditionSynthesis(groups: [group], unassigned: [])), as: UTF8.self)
        }
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertTrue(result.unassigned.isEmpty)
        try result.validate(facts)
    }

}
