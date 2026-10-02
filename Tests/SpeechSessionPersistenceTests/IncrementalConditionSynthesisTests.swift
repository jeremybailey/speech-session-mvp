import XCTest
@testable import SpeechSessionPersistence

final class IncrementalConditionSynthesisTests: XCTestCase {
    func testLargeHistoryManifestDoesNotUseSingleInferenceLimit() throws {
        let facts = (0..<900).map { fact("Synthetic concern \($0) " + String(repeating: "source-backed detail ", count: 35)) }
        XCTAssertThrowsError(try ConditionSynthesis.input(facts))
        let raw = try ConditionSynthesis.conditionWorkflowInput(plan: ConditionSynthesis.initialIncrementalPlan(facts: facts), facts: facts)
        XCTAssertGreaterThan(raw.utf8.count, 400_000)
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        let batches = object["batches"] as! [[[String: Any]]]
        XCTAssertEqual(batches.flatMap { $0 }.count, 900)
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.count, 30)
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: ["entries": batch]).count, 24_000)
        }
        XCTAssertEqual(raw, try ConditionSynthesis.conditionWorkflowInput(plan: ConditionSynthesis.initialIncrementalPlan(facts: facts), facts: facts))
    }
    func testServerWorkflowPlanPreservesSourceAndExcludesReviewState() throws {
        let pregnancy = fact("Pregnancy"), followup = fact("Pregnancy follow-up")
        let prior = ConditionSynthesis(groups: [group("Pregnancy", [pregnancy])], unassigned: [])
        let facts = [pregnancy, followup]
        let plan = ConditionSynthesis.incrementalPlan(previous: prior,
            versions: ConditionSynthesis.clinicalVersions([pregnancy]), facts: facts)
        let raw = try ConditionSynthesis.conditionWorkflowInput(plan: plan, facts: facts)
        let payload = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        XCTAssertEqual(payload["workload_type"] as? String, "incremental")
        let initial = try ConditionSynthesis.conditionWorkflowInput(plan: ConditionSynthesis.initialIncrementalPlan(facts: facts), facts: facts)
        let initialPayload = try JSONSerialization.jsonObject(with: Data(initial.utf8)) as! [String: Any]
        XCTAssertEqual(initialPayload["workload_type"] as? String, "initial")
        XCTAssertEqual((payload["batches"] as! [[[String: Any]]])[0][0]["id"] as? String, followup.latest.id.uuidString)
        XCTAssertEqual((payload["contextEntries"] as! [[String: Any]])[0]["id"] as? String, pregnancy.latest.id.uuidString)
        XCTAssertFalse(raw.contains("manualReviewed"))
        let restored = try JSONDecoder().decode(ConditionSynthesis.self,
            from: JSONSerialization.data(withJSONObject: payload["preserved"]!))
        XCTAssertEqual(restored.groups[0].stableID, prior.groups[0].stableID)
    }
    private func fact(_ title: String) -> HealthFact {
        let entry = SummaryEntry(category: .symptoms, title: title, origin: .userAdded)
        return HealthFact(id: entry.id.uuidString, occurrences: [entry], preference: .init(id: entry.id.uuidString), topicIDs: [])
    }
    private func group(_ name: String, _ facts: [HealthFact]) -> ConditionSynthesis.Group {
        .init(name: name, bodySystem: "reproductive", isPrimary: false, reason: "Explicit source episode",
              entryIDs: facts.map { $0.latest.id }, stableID: UUID())
    }
    private func encoded(_ value: ConditionSynthesis) throws -> String {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        object["groups"] = (object["groups"] as! [[String: Any]]).map { original in
            var group = original
            group["entryIDs"] = (original["entryIDs"] as! [String]).enumerated().map { "r\($0.offset + 1)" }
            return group
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    private func decision(_ name: String, _ ids: [UUID]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["decisions": [[
            "name": name, "bodySystem": "reproductive", "nameSupported": true,
            "supportedEntryIDs": ids.enumerated().map { "r\($0.offset + 1)" }, "reason": "Source explicitly identifies the episode"
        ]]]), as: UTF8.self)
    }

    func testUnchangedReopeningHasZeroRequestsAndKeepsIdentity() async throws {
        let facts = [fact("Pregnancy")]
        let previous = ConditionSynthesis(groups: [group("Pregnancy", facts)], unassigned: [])
        let plan = ConditionSynthesis.incrementalPlan(previous: previous, versions: ConditionSynthesis.clinicalVersions(facts), facts: facts)
        let result = try await ConditionSynthesis.organizeIncrementally(plan: plan, facts: facts, mapping: { _ in
            XCTFail("Unchanged history must not map"); return ""
        }, verification: { _ in XCTFail("Unchanged history must not verify"); return "" })
        XCTAssertEqual(result.groups.first?.stableID, previous.groups.first?.stableID)
    }

    func testNewCareLinkUsesContextButNeverRemapsAcceptedRecord() async throws {
        let pregnancy = fact("Pregnancy"), followup = fact("Follow-up for this pregnancy in two weeks")
        let prior = ConditionSynthesis(groups: [group("Pregnancy", [pregnancy])], unassigned: [])
        let facts = [pregnancy, followup]
        let plan = ConditionSynthesis.incrementalPlan(previous: prior, versions: ConditionSynthesis.clinicalVersions([pregnancy]), facts: facts)
        let result = try await ConditionSynthesis.organizeIncrementally(plan: plan, facts: facts, mapping: { input in
            XCTAssertFalse(input.contains(pregnancy.latest.id.uuidString))
            XCTAssertFalse(input.contains(followup.latest.id.uuidString))
            XCTAssertTrue(input.contains("r1"))
            XCTAssertFalse(input.contains("manualReviewed"), "Presentation state must not change request cache keys")
            XCTAssertTrue(input.contains("existingGroups"))
            return try self.encoded(.init(groups: [self.group("Pregnancy", [followup])], unassigned: []))
        }, verification: { input in
            XCTAssertTrue(input.contains("acceptedContext"))
            XCTAssertFalse(input.contains(pregnancy.latest.id.uuidString))
            return try self.decision("Pregnancy", [followup.latest.id])
        })
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].stableID, prior.groups[0].stableID)
        XCTAssertEqual(Set(result.groups[0].entryIDs), Set(facts.map { $0.latest.id }))
        XCTAssertNotNil(result.groups[0].entryReasons?[followup.latest.id])
    }

    func testEditOrDeletionRechecksDependentGroupButNotUnrelatedGroup() {
        let anchor = fact("Pregnancy"), care = fact("Pregnancy medication"), other = fact("Migraine")
        let old = [anchor, care, other]
        let prior = ConditionSynthesis(groups: [group("Pregnancy", [anchor, care]), group("Migraine", [other])], unassigned: [])
        var edited = anchor
        edited.occurrences[0].title = "Pregnancy ruled out"
        for current in [[edited, care, other], [care, other]] {
            let plan = ConditionSynthesis.incrementalPlan(previous: prior, versions: ConditionSynthesis.clinicalVersions(old), facts: current)
            XCTAssertEqual(plan.preserved.groups.map(\.name), ["Migraine"])
            XCTAssertTrue(plan.candidates.contains { $0.latest.id == care.latest.id })
            XCTAssertFalse(plan.candidates.contains { $0.latest.id == other.latest.id })
        }
    }

    func testManualChoicesExcludedAndRestoringAutomaticRequiresMapping() {
        var manual = fact("Pregnancy")
        manual.preference.topicIDs = []
        let initial = ConditionSynthesis.initialIncrementalPlan(facts: [manual])
        XCTAssertTrue(initial.candidates.isEmpty)
        XCTAssertEqual(initial.preserved.unassigned, [manual.latest.id])
        var automatic = manual
        automatic.preference.topicIDs = nil
        let plan = ConditionSynthesis.incrementalPlan(previous: initial.preserved,
            versions: ConditionSynthesis.clinicalVersions([manual]), facts: [automatic])
        XCTAssertEqual(plan.candidates.count, 1)
    }

    func testWeakLinkRemovedWithoutTouchingAcceptedGroup() async throws {
        let old = fact("Pregnancy"), weak = fact("Same clinician ordered an unrelated eye test")
        let prior = ConditionSynthesis(groups: [group("Pregnancy", [old])], unassigned: [])
        let facts = [old, weak]
        let plan = ConditionSynthesis.incrementalPlan(previous: prior, versions: ConditionSynthesis.clinicalVersions([old]), facts: facts)
        let result = try await ConditionSynthesis.organizeIncrementally(plan: plan, facts: facts, mapping: { _ in
            try self.encoded(.init(groups: [self.group("Pregnancy", [weak])], unassigned: []))
        }, verification: { _ in try self.decision("Pregnancy", []) })
        XCTAssertEqual(result.groups[0].entryIDs, [old.latest.id])
        XCTAssertEqual(result.unassigned, [weak.latest.id])
    }

    func testMalformedCoverageCannotTriggerAutomaticRetry() async throws {
        let facts = [fact("Pregnancy")]
        var calls = 0
        do {
            _ = try await ConditionSynthesis.organizeIncrementally(plan: .init(preserved: .init(groups: [], unassigned: []), candidates: facts),
                facts: facts, mapping: { _ in calls += 1; return "{\"groups\":[],\"unassigned\":[]}" },
                verification: { _ in XCTFail("Invalid coverage must stop before verification"); return "" })
            XCTFail("Missing coverage must fail")
        } catch { XCTAssertTrue(error is ConditionSynthesis.SynthesisError) }
        XCTAssertEqual(calls, 1)
    }

    func testSavedGroupIdentitySurvivesReloadAndLocalMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        try await store.upsert(Session(transcript: "Synthetic", summaryEntries: [fact("Pregnancy").latest]))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        var legacy = group("Pregnancy", facts); legacy.stableID = nil
        try await store.saveConditionSynthesis(.init(groups: [legacy], unassigned: []), expected: facts)
        let first = await store.conditionSynthesis(for: facts)
        let reopened = try SessionStore(storageDirectory: directory)
        let second = await reopened.conditionSynthesis(for: facts)
        XCTAssertNotNil(first?.groups[0].stableID)
        XCTAssertEqual(first?.groups[0].stableID, second?.groups[0].stableID)
        legacy.name = "Reported pregnancy"
        try await reopened.saveConditionSynthesis(.init(groups: [legacy], unassigned: []), expected: facts)
        let renamed = await reopened.conditionSynthesis(for: facts)
        XCTAssertEqual(renamed?.groups[0].stableID, first?.groups[0].stableID, "A name change must not create a new condition identity")
        let plan = await reopened.incrementalConditionPlan(for: facts + [fact("New detail")])
        XCTAssertEqual(plan?.candidates.count, 1)
    }

    func testInterruptedIncrementalRunReusesCompletedPortion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        try await store.upsert(Session(transcript: "Synthetic", summaryEntries: (0..<31).map { fact("Uncertain detail \($0)").latest }))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        let plan = ConditionSynthesis.initialIncrementalPlan(facts: facts)
        var dispatches = 0
        func mapping(_ input: String) async throws -> String {
            if let saved = await store.conditionResponse(for: facts, key: input) { return saved }
            dispatches += 1
            if dispatches == 2 { throw CancellationError() }
            let rows = (try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any])["entries"] as! [[String: Any]]
            let response = String(decoding: try JSONSerialization.data(withJSONObject: ["groups": [], "unassigned": rows.map { $0["id"] as! String }]), as: UTF8.self)
            try await store.saveConditionResponse(response, for: facts, key: input)
            return response
        }
        do {
            _ = try await ConditionSynthesis.organizeIncrementally(plan: plan, facts: facts, mapping: mapping,
                verification: { _ in XCTFail("No proposed links to verify"); return "" })
            XCTFail("Expected simulated interruption")
        } catch { XCTAssertTrue(error is CancellationError) }
        let result = try await ConditionSynthesis.organizeIncrementally(plan: plan, facts: facts, mapping: mapping,
            verification: { _ in XCTFail("No proposed links to verify"); return "" })
        XCTAssertEqual(dispatches, 3, "Completed first portion must not be dispatched again")
        XCTAssertEqual(result.unassigned.count, 31)
    }

    func testInventedLocalIdentifierFailsClosed() async throws {
        let facts = [fact("Pregnancy")]
        do {
            _ = try await ConditionSynthesis.organizeIncrementally(plan: ConditionSynthesis.initialIncrementalPlan(facts: facts),
                facts: facts, mapping: { _ in "{\"groups\":[],\"unassigned\":[\"r999\"]}" },
                verification: { _ in XCTFail("Invented IDs must stop before verification"); return "" })
            XCTFail("Invented local ID must fail")
        } catch { XCTAssertTrue(error is ConditionSynthesis.SynthesisError) }
    }
}
