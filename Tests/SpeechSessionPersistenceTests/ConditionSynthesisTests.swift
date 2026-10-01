import XCTest
@testable import SpeechSessionPersistence

final class ConditionSynthesisTests: XCTestCase {
    func testLegacyCompletedCacheMigratesWithoutInference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        try await store.upsert(Session(transcript: "Synthetic", summaryEntries: [fact("Pregnancy").latest]))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        struct Legacy: Encodable { let fingerprint: String; let synthesis: ConditionSynthesis }
        let saved = Legacy(fingerprint: ConditionSynthesis.legacyFingerprint(facts), synthesis: synthesis(facts))
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("condition-synthesis.json"))
        let reused = await store.conditionSynthesis(for: facts)
        XCTAssertNotNil(reused)
        var reviewed = facts
        reviewed[0].preference.reviewedRevision = "reviewed"
        let afterReview = await store.conditionSynthesis(for: reviewed)
        XCTAssertNotNil(afterReview)
    }
    func testReviewAndVisibilityDoNotInvalidateClinicalProcessing() {
        let original = fact("Pregnancy")
        var changed = original
        changed.preference.hidden = true
        changed.preference.reviewedRevision = "new-review"
        XCTAssertEqual(ConditionSynthesis.fingerprint([original]), ConditionSynthesis.fingerprint([changed]))
        changed.preference.topicIDs = []
        XCTAssertNotEqual(ConditionSynthesis.fingerprint([original]), ConditionSynthesis.fingerprint([changed]))
    }
    func testEditedRecoveredEntryDoesNotHideUnchangedConditionMembers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let first = fact("Pregnancy"), second = fact("Pregnancy care")
        try await store.upsert(Session(transcript: "Synthetic", summaryEntries: [first.latest, second.latest]))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        var result = synthesis(facts)
        result.groups[0].entryReasons = [first.latest.id: "Reported pregnancy"]
        try await store.saveConditionSynthesis(result, expected: facts)
        var changed = facts
        let index = changed.firstIndex { $0.latest.id == first.latest.id }!
        changed[index].occurrences[0].title = "Edited"
        let displayed = await store.displayedConditionFacts(for: changed)
        XCTAssertNotNil(displayed.first { $0.latest.id == second.latest.id }?.latest.evidence?.conditionGroup)
        XCTAssertEqual(displayed[index].latest.evidence?.conditionSynthesisUnassigned, true)
    }
    func testRecoveryUsesBoundedBatches() async throws {
        let anchor = fact("Pregnancy")
        let candidates = (0..<65).map { fact("Care detail \($0)") }
        let facts = [anchor] + candidates
        let proposal = ConditionSynthesis(groups: [.init(name: "Pregnancy", bodySystem: "reproductive", isPrimary: false, reason: "Reported pregnancy", entryIDs: [anchor.latest.id])], unassigned: candidates.map { $0.latest.id })
        var counts: [Int] = []
        let result = try await ConditionSynthesis.recoveringContext(proposal, facts: facts) { input in
            let object = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
            let rows = object["entries"] as! [[String: Any]]
            counts.append(rows.count)
            return String(decoding: try JSONSerialization.data(withJSONObject: ["links": [], "unassigned": rows.map { $0["id"] as! String }]), as: UTF8.self)
        }
        XCTAssertEqual(counts, [30, 30, 5])
        try result.validate(facts)
    }

    func testExactRequestSurvivesRelaunchAndUnrelatedHistoryChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        try await store.upsert(Session(transcript: "Synthetic", summaryEntries: [fact("Pregnancy").latest]))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        try await store.saveConditionResponse("completed", for: facts, key: "verification-payload")
        let reopened = try SessionStore(storageDirectory: directory)
        let restored = await reopened.conditionResponse(for: facts, key: "verification-payload")
        XCTAssertEqual(restored, "completed")
        let changed = await reopened.conditionResponse(for: facts + [fact("New detail")], key: "verification-payload")
        XCTAssertEqual(changed, "completed")
        let editedRequest = await reopened.conditionResponse(for: facts, key: "different-verification-payload")
        XCTAssertNil(editedRequest)
        try await reopened.upsert(Session(transcript: "Additional synthetic", summaryEntries: [fact("Migraine").latest]))
        let expanded = HealthMemoryProjection.facts(in: try await reopened.healthSnapshot(), verifiedOnly: true)
        try await reopened.saveConditionResponse("new completed", for: expanded, key: "new-payload")
        let retained = await reopened.conditionResponse(for: expanded, key: "verification-payload")
        XCTAssertEqual(retained, "completed", "Saving a new request must preserve unaffected completed requests")
        try await reopened.discardConditionResponse(for: facts + [fact("New detail")], key: "verification-payload")
        let discarded = await reopened.conditionResponse(for: facts, key: "verification-payload")
        XCTAssertNil(discarded)
    }

    func testExactRequestExpiresAndDoesNotPersistClinicalRequestKeys() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        try await store.upsert(Session(transcript: "Synthetic", summaryEntries: [fact("Pregnancy").latest]))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        let key = "synthetic confidential source request"
        try await store.saveConditionResponse("completed", for: facts, key: key)
        let url = directory.appendingPathComponent("condition-exact-requests.json")
        let data = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(key))
        struct Cached: Codable { var response: String; var expiresAt: Date }
        var cache = try JSONDecoder().decode([String: Cached].self, from: data)
        for id in Array(cache.keys) { cache[id]?.expiresAt = Date(timeIntervalSince1970: 0) }
        try JSONEncoder().encode(cache).write(to: url)
        let expired = await store.conditionResponse(for: facts, key: key)
        XCTAssertNil(expired)
        XCTAssertEqual(try JSONDecoder().decode([String: Cached].self, from: Data(contentsOf: url)).count, 0)
    }

    func testChangedPatientDataCannotSaveAnInFlightResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let session = Session(transcript: "Synthetic", summaryEntries: [fact("Pregnancy").latest])
        try await store.upsert(session)
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        try await store.upsert(Session(transcript: "Additional", summaryEntries: [fact("Migraine").latest]))
        do {
            try await store.saveConditionResponse("stale", for: facts, key: "payload")
            XCTFail("Must not save an in-flight response after the patient's data changes")
        } catch { XCTAssertTrue(error is SummaryCommitError) }
    }
    func testIndependentVerificationCanOnlyRemoveUnsupportedEdges() async throws {
        let facts = [fact("Migraine", category: .symptoms), fact("Normal chest x-ray", category: .testsAndLabs)]
        let ids = facts.flatMap(\.occurrences).map(\.id)
        let proposed = ConditionSynthesis(groups: [
            .init(name: "Migraine", bodySystem: "neurological", isPrimary: true,
                  reason: "Proposed relationship", entryIDs: ids)
        ], unassigned: [])
        let verified = try await ConditionSynthesis.verified(proposed, facts: facts) { _ in
            """
            {"decisions":[{"name":"Migraine","bodySystem":"neurological","nameSupported":true,"supportedEntryIDs":["\(ids[0].uuidString)"],"reason":"The migraine entry explicitly names the concern."}]}
            """
        }
        XCTAssertEqual(verified.groups.first?.entryIDs, [ids[0]])
        XCTAssertEqual(verified.unassigned, [ids[1]])
    }

    func testIndependentVerificationRejectsInventedConditionName() async throws {
        let facts = [fact("Dry eye", category: .symptoms)]
        let id = facts[0].latest.id
        let proposed = ConditionSynthesis(groups: [
            .init(name: "Neurotrophic keratitis", bodySystem: "eye", isPrimary: false,
                  reason: "Inferred diagnosis", entryIDs: [id])
        ], unassigned: [])
        let verified = try await ConditionSynthesis.verified(proposed, facts: facts) { _ in
            """
            {"decisions":[{"name":"Neurotrophic keratitis","bodySystem":"eye","nameSupported":false,"supportedEntryIDs":[],"reason":"The diagnosis is not explicitly supported."}]}
            """
        }
        XCTAssertTrue(verified.groups.isEmpty)
        XCTAssertEqual(verified.unassigned, [id])
    }

    func testContextRecoveryAddsSourceBackedPregnancyCareAndPreservesReason() async throws {
        var pregnancy = fact("Pregnancy", category: .symptoms)
        pregnancy.occurrences[0].details = "Currently pregnant."
        var aspirin = fact("Continue taking baby aspirin until 36 weeks.", category: .carePlan)
        aspirin.occurrences[0].details = "Continue during pregnancy until 36 weeks."
        let pregnancyID = pregnancy.latest.id, aspirinID = aspirin.latest.id
        let initial = ConditionSynthesis(groups: [
            .init(name: "Pregnancy", bodySystem: "reproductive", isPrimary: true,
                  reason: "The patient reports pregnancy.", entryIDs: [pregnancyID])
        ], unassigned: [aspirinID])

        let recovered = try await ConditionSynthesis.recoveringContext(initial, facts: [pregnancy, aspirin]) { payload in
            XCTAssertTrue(payload.contains("Continue taking baby aspirin"))
            XCTAssertTrue(payload.contains("Pregnancy"))
            return """
            {"links":[{"name":"Pregnancy","bodySystem":"reproductive","entryID":"\(aspirinID.uuidString)","reason":"The plan explicitly says to continue it during pregnancy."}],"unassigned":[]}
            """
        }
        XCTAssertEqual(Set(recovered.groups[0].entryIDs), Set([pregnancyID, aspirinID]))
        XCTAssertEqual(recovered.groups[0].entryReasons?[aspirinID], "The plan explicitly says to continue it during pregnancy.")
        let projected = recovered.applying(to: [pregnancy, aspirin])
        XCTAssertEqual(projected[1].latest.evidence?.conditionGroupReason, "The plan explicitly says to continue it during pregnancy.")

        let verified = try await ConditionSynthesis.verified(recovered, facts: [pregnancy, aspirin]) { _ in
            """
            {"decisions":[{"name":"Pregnancy","bodySystem":"reproductive","nameSupported":true,"supportedEntryIDs":["\(pregnancyID.uuidString)"],"reason":"Only the reported pregnancy is supported by this source."}]}
            """
        }
        XCTAssertEqual(verified.groups[0].entryIDs, [pregnancyID])
        XCTAssertEqual(verified.unassigned, [aspirinID])
    }

    func testContextRecoveryRejectsUnknownConcernAndLeavesRecordUnassigned() async throws {
        let pregnancy = fact("Pregnancy", category: .symptoms)
        let unrelated = fact("Routine eye examination", category: .testsAndLabs)
        let initial = ConditionSynthesis(groups: [
            .init(name: "Pregnancy", bodySystem: "reproductive", isPrimary: true,
                  reason: "The patient reports pregnancy.", entryIDs: [pregnancy.latest.id])
        ], unassigned: [unrelated.latest.id])
        do {
            _ = try await ConditionSynthesis.recoveringContext(initial, facts: [pregnancy, unrelated]) { _ in
                """
                {"links":[{"name":"Unrelated eye concern","bodySystem":"eye","entryID":"\(unrelated.latest.id.uuidString)","reason":"Not an established concern."}],"unassigned":[]}
                """
            }
            XCTFail("A context recovery response must use an established concern.")
        } catch {
            XCTAssertTrue(error is ConditionSynthesis.SynthesisError)
        }
    }
    func testTransientRequestRecoversWithSamePayloadAndBoundedBackoff() async throws {
        var attempts = 0
        var delays: [UInt64] = []
        let result = try await ConditionSynthesis.requestWithTransientRetry("accepted entries", sleep: { delays.append($0) }) { payload in
            XCTAssertEqual(payload, "accepted entries")
            attempts += 1
            if attempts < 3 { throw URLError(.networkConnectionLost) }
            return "completed"
        }
        XCTAssertEqual(result, "completed")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, [2_000_000_000, 4_000_000_000])
    }

    func testPersistentNetworkFailureStopsAfterThreeAttempts() async {
        var attempts = 0
        do {
            _ = try await ConditionSynthesis.requestWithTransientRetry("input", sleep: { _ in }) { _ in
                attempts += 1
                throw URLError(.timedOut)
            }
            XCTFail("Must report persistent failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(attempts, 3)
    }

    func testNonTransientErrorsAreNotRetried() async {
        for error in [URLError(.cancelled) as Error, URLError(.userAuthenticationRequired), ConditionSynthesis.SynthesisError.invalid] {
            var attempts = 0
            do {
                _ = try await ConditionSynthesis.requestWithTransientRetry("input", sleep: { _ in XCTFail("Must not delay") }) { _ in
                    attempts += 1
                    throw error
                }
                XCTFail("Must propagate error")
            } catch { }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testCancellationDuringBackoffStopsRetry() async {
        var attempts = 0
        do {
            _ = try await ConditionSynthesis.requestWithTransientRetry("input", sleep: { _ in throw CancellationError() }) { _ in
                attempts += 1
                throw URLError(.networkConnectionLost)
            }
            XCTFail("Must cancel")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }

    func testDroppedConnectionInLaterBatchDoesNotRepeatCompletedBatch() async throws {
        let facts = (0..<61).map { fact("Synthetic concern \($0)") }
        var calls: [String: Int] = [:]
        let result = try await ConditionSynthesis.organize(facts: facts) { payload in
            calls[payload, default: 0] += 1
            let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
            let rows = json["entries"] as! [[String: Any]]
            if rows.count == 1 && calls[payload] == 1 { throw URLError(.networkConnectionLost) }
            let ids = rows.map { $0["id"] as! String }
            let response: [String: Any] = ["groups": [], "unassigned": ids]
            return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        }
        try result.validate(facts)
        XCTAssertEqual(result.unassigned.count, 61)
        XCTAssertEqual(calls.values.sorted(), [1, 2])
    }

    func testCheckpointedGroupingResumesAtFirstUnfinishedBatch() async throws {
        let facts = (0..<61).map { fact("Checkpoint concern \($0)") }
        var checkpoint: ConditionSynthesis.GroupingCheckpoint?
        var firstRunCalls = 0
        do {
            _ = try await ConditionSynthesis.organizeWithExternalRecovery(
                facts: facts,
                saveCheckpoint: { checkpoint = $0 }
            ) { payload in
                firstRunCalls += 1
                if firstRunCalls == 2 { throw CancellationError() }
                let rows = (try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any])["entries"] as! [[String: Any]]
                let ids = rows.map { $0["id"] as! String }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["groups": [], "unassigned": ids]), as: UTF8.self)
            }
            XCTFail("The second batch should be interrupted")
        } catch is CancellationError { }
        XCTAssertEqual(checkpoint?.completed.count, 1)

        var resumedPayloadSizes: [Int] = []
        let result = try await ConditionSynthesis.organizeWithExternalRecovery(facts: facts, checkpoint: checkpoint) { payload in
            let rows = (try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any])["entries"] as! [[String: Any]]
            resumedPayloadSizes.append(rows.count)
            let ids = rows.map { $0["id"] as! String }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["groups": [], "unassigned": ids]), as: UTF8.self)
        }
        try result.validate(facts)
        XCTAssertEqual(resumedPayloadSizes, [1])
    }

    func testTokenEstimateSplitsBeforeByteLimit() async throws {
        let largeDetail = String(repeating: "clinical context ", count: 1_150)
        let facts = (0..<3).map { index -> HealthFact in
            var entry = SummaryEntry(category: .otherNotes, title: "Concern \(index)", details: largeDetail,
                                     origin: .userAdded)
            entry.evidence = ClinicalEvidence()
            return HealthFact(id: entry.id.uuidString, occurrences: [entry],
                              preference: .init(id: entry.id.uuidString), topicIDs: [])
        }
        var payloadSizes: [Int] = []
        let result = try await ConditionSynthesis.organize(facts: facts) { payload in
            payloadSizes.append(payload.utf8.count)
            let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
            let rows = json["entries"] as! [[String: Any]]
            let ids = rows.map { $0["id"] as! String }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["groups": [], "unassigned": ids]),
                          as: UTF8.self)
        }
        try result.validate(facts)
        XCTAssertGreaterThan(payloadSizes.count, 1)
        XCTAssertTrue(payloadSizes.allSatisfy { $0 < 60_000 })
    }

    func testCompletedConditionProposalResumesAfterRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = SummaryEntry(category: .symptoms, title: "Migraine", origin: .userAdded)
        let session = Session(transcript: "Patient reports migraine.", summaryEntries: [entry])
        let store = try SessionStore(storageDirectory: dir)
        try await store.upsert(session)
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        let proposal = synthesis(facts, name: "Migraine")
        try await store.saveConditionProposal(proposal, expected: facts, model: ConditionSynthesis.model,
                                              promptVersion: ConditionSynthesis.promptVersion)

        let relaunched = try SessionStore(storageDirectory: dir)
        let restored = await relaunched.conditionProposal(for: facts, model: ConditionSynthesis.model,
                                                           promptVersion: ConditionSynthesis.promptVersion)
        XCTAssertEqual(restored?.groups.first?.name, "Migraine")
        XCTAssertEqual(restored?.groups.first?.entryIDs, proposal.groups.first?.entryIDs)
    }

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
