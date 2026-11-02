import XCTest
@testable import SpeechSessionPersistence

final class CarePlanOrganizationTests: XCTestCase {
    private let source = "The midwife recommended taking aspirin until 36 weeks. If pain increases, call the clinic. The patient declined borrowing a TENS machine."
    private func original(_ id: UUID = UUID(), sessionID: UUID = UUID()) -> SummaryEntry {
        var e = SummaryEntry(id: id, category: .carePlan, title: "Aspirin", details: "The midwife recommended taking aspirin until 36 weeks.", sourceSessionID: sessionID)
        e.evidence = ClinicalEvidence()
        return e
    }
    private func response(_ entry: SummaryEntry, headline: String = "Take aspirin until 36 weeks", bucket: String = "carePlan", owner: String? = nil) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["rows":[["id":entry.id.uuidString,"headline":headline,"bucket":bucket,"owner":owner as Any? ?? NSNull(),"consideration":NSNull()]]]), as: UTF8.self)
    }
    private func checked(_ entry: SummaryEntry, quote: String? = nil) -> SummaryEntry {
        let c = SummaryCheck(id: entry.id, supported: true, reason: "Supported", citations: SummaryVerification.requiredFields(entry).map { .init(field:$0, excerpt:quote ?? source) })
        return SummaryVerification.assess(entry, check:c, source:source)
    }
    func testLegacyDecodingAndNoKeywordRouting() throws {
        let instruction = try JSONDecoder().decode(CareInstruction.self, from: Data("{\"instruction\":\"If pain increases, call\"}".utf8))
        XCTAssertNil(instruction.bucket)
        XCTAssertEqual(instruction.instruction, "If pain increases, call")
    }
    func testStrictIdentityAndOwnerContract() throws {
        let e = original()
        XCTAssertThrowsError(try CarePlanOrganization.drafts(response(e, bucket:"other"), originals:[e]))
        XCTAssertThrowsError(try CarePlanOrganization.drafts(response(e, owner:"Asha"), originals:[e]))
        XCTAssertThrowsError(try CarePlanOrganization.drafts(response(original()), originals:[e]))
        XCTAssertThrowsError(try CarePlanOrganization.drafts("{\"rows\":[]}", originals:[e]))
        XCTAssertThrowsError(try CarePlanOrganization.drafts("refused", originals:[e]))
    }
    func testHeadlinePreservesReturnedQualifiersAndMetadataIsChecked() throws {
        let e = original()
        for headline in ["If pain increases, call the clinic", "Declined borrowing a TENS machine", "Do not stop aspirin before review", "Patient recalls advice to take aspirin until 36 weeks"] {
            let draft = try CarePlanOrganization.drafts(response(e, headline:headline, bucket:"considerations"), originals:[e])[0]
            XCTAssertEqual(draft.evidence?.careInstruction?.instruction,headline)
            XCTAssertEqual(draft.title,e.title)
            XCTAssertEqual(draft.details,e.details)
            XCTAssertTrue(SummaryVerification.requiredFields(draft).contains("careInstruction"))
            XCTAssertEqual(checked(draft,quote:"invented quotation").evidence?.assessment?.admission,.sourceOnly)
            let rejection = SummaryCheck(id:draft.id,supported:false,reason:"Wrong person or unsupported qualifier",citations:[])
            XCTAssertEqual(SummaryVerification.assess(draft,check:rejection,source:source).evidence?.assessment?.admission,.sourceOnly)
        }
    }
    func testUploadDateIsNotSourceDate() {
        let id = UUID()
        var e = original(sessionID:id); e.sourceDate = Date()
        let document = Session(id:id,transcript:source,inputType:.documentFile)
        XCTAssertNil(CareInstructionPresentation.sourceOrderDate(e,sessions:[document]))
        XCTAssertTrue(CareInstructionPresentation.dateLabel(e,sessions:[document]).contains("Added"))
        e.evidence?.eventDate = "2024"
        XCTAssertEqual(CareInstructionPresentation.dateLabel(e,sessions:[document]),"Recorded: 2024")
        let audio = Session(id:id,transcript:source,inputType:.audio)
        XCTAssertEqual(CareInstructionPresentation.sourceOrderDate(e,sessions:[audio]),e.sourceDate)
    }
    func testAtomicSaveRestartAndStaleEditProtection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try SessionStore(storageDirectory:directory)
        let id = UUID(); let e = original(sessionID:id)
        try await store.upsert(Session(id:id,transcript:source,summaryEntries:[e]))
        let draft = try CarePlanOrganization.drafts(response(e),originals:[e])[0]
        let valid = checked(draft)
        try await store.publishCareOrganization(sessionID:id,source:source,originals:[e],replacements:[valid])
        let reopened = try SessionStore(storageDirectory:directory)
        let snap = try await reopened.healthSnapshot()
        XCTAssertEqual(snap.sessions[0].summaryEntries?[0].evidence?.careInstruction?.bucket,.carePlan)
        XCTAssertEqual(snap.sessions[0].summaryEntries?[0].id,e.id)
        var edit = valid; edit.details = "My edit"; edit.origin = .userEdited
        try await reopened.saveSummaryEntry(edit)
        do {
            try await reopened.publishCareOrganization(sessionID:id,source:source,originals:[valid],replacements:[valid])
            XCTFail("Stale snapshot was accepted")
        } catch { }
        let after = try await reopened.healthSnapshot()
        XCTAssertEqual(after.sessions[0].summaryEntries?[0].details,"My edit")
    }
    func testConsiderationsNeverBecomeNextSteps() throws {
        var e = original()
        e.evidence?.actionKind = "homecare"
        e.evidence?.careInstruction = CareInstruction(instruction:"If symptoms worsen, call")
        e.evidence?.careInstruction?.bucket = .considerations
        let fact = HealthFact(id:"sample",occurrences:[e],preference:HealthFactPreference(id:"sample"),topicIDs:[])
        XCTAssertFalse(fact.isAction)
        XCTAssertFalse(fact.canShowAsNextStep)
    }
    func testSourceRecencySortDoesNotPromoteNewUploads() {
        let oldID = UUID(), recentID = UUID(), uploadID = UUID()
        var old = original(sessionID:oldID); old.sourceDate = Date(timeIntervalSince1970:1)
        var recent = original(sessionID:recentID); recent.sourceDate = Date(timeIntervalSince1970:100)
        var upload = original(sessionID:uploadID); upload.sourceDate = Date(timeIntervalSince1970:1000)
        func fact(_ e: SummaryEntry) -> HealthFact {
            HealthFact(id:e.id.uuidString,occurrences:[e],preference:HealthFactPreference(id:e.id.uuidString),topicIDs:[])
        }
        let sessions = [Session(id:oldID,transcript:"",inputType:.audio),Session(id:recentID,transcript:"",inputType:.audio),Session(id:uploadID,transcript:"",inputType:.documentFile)]
        XCTAssertEqual(CareInstructionPresentation.sorted([fact(old),fact(upload),fact(recent)],sessions:sessions).map(\.latest.id),[recent.id,old.id,upload.id])
    }
    func testFailedBatchPublishesNothingAndDoesNotChangeFacts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try SessionStore(storageDirectory:directory)
        let id = UUID(); let a = original(sessionID:id), b = original(sessionID:id)
        try await store.upsert(Session(id:id,transcript:source,summaryEntries:[a,b]))
        let da = try CarePlanOrganization.drafts(response(a),originals:[a])[0]
        let db = try CarePlanOrganization.drafts(response(b),originals:[b])[0]
        var tampered = db; tampered.details = "Different underlying fact"
        do {
            try await store.publishCareOrganization(sessionID:id,source:source,originals:[a,b],replacements:[checked(da),checked(tampered)])
            XCTFail("Underlying changes were accepted")
        } catch { }
        let snap = try await store.healthSnapshot()
        XCTAssertEqual(snap.sessions[0].summaryEntries,[a,b])
    }

    func testSourceRejectionIsNotReportedAsMalformedResponse() throws {
        let entry = original()
        let draft = try CarePlanOrganization.drafts(response(entry), originals: [entry])[0]
        let check = SummaryCheck(id: draft.id, supported: false, reason: "Unsupported attribution", citations: [])
        let data = try JSONSerialization.data(withJSONObject: ["decisions": [draft.id.uuidString:
            JSONSerialization.jsonObject(with: JSONEncoder().encode(check))]])
        XCTAssertThrowsError(try CarePlanOrganization.checkedDrafts(String(decoding: data, as: UTF8.self), drafts: [draft], source: source)) {
            XCTAssertEqual($0 as? CarePlanOrganization.ValidationError, .sourceCheckRejected(1))
        }
        XCTAssertThrowsError(try CarePlanOrganization.checkedDrafts("{}", drafts: [draft], source: source)) {
            XCTAssertEqual($0 as? SummaryResponseError, .invalidFormat)
        }
        let valid = SummaryCheck(id: draft.id, supported: true, reason: "Supported", citations:
            SummaryVerification.requiredFields(draft).map { .init(field: $0, excerpt: source) })
        let validData = try JSONSerialization.data(withJSONObject: ["decisions": [draft.id.uuidString:
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))]])
        XCTAssertEqual(try CarePlanOrganization.checkedDrafts(String(decoding: validData, as: UTF8.self), drafts: [draft], source: source).first?.evidence?.assessment?.admission, .supported)
    }

    func testMixedSourceVerdictsPublishSupportedSubsetAndKeepRejectedOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let sessionID = UUID()
        let a = original(sessionID: sessionID), b = original(sessionID: sessionID)
        try await store.upsert(Session(id: sessionID, transcript: source, summaryEntries: [a, b]))
        let drafts = try [a, b].map { try CarePlanOrganization.drafts(response($0), originals: [$0])[0] }
        let checks = [
            SummaryCheck(id: a.id, supported: true, reason: "Supported", citations:
                SummaryVerification.requiredFields(drafts[0]).map { .init(field: $0, excerpt: source) }),
            SummaryCheck(id: b.id, supported: false, reason: "The headline omits the source condition", citations: [])
        ]
        let raw = try SummarySourceCheck.keyedResponse(checks, expectedIDs: drafts.map(\.id))
        let assessed = try CarePlanOrganization.assessedDrafts(raw, drafts: drafts, source: source)
        XCTAssertEqual(assessed.map { $0.evidence?.assessment?.admission }, [.supported, .sourceOnly])
        let supported = assessed.filter { $0.evidence?.assessment?.admission == .supported }
        try await store.publishCareOrganization(sessionID: sessionID, source: source, originals: [a], replacements: supported)
        let saved = try await store.healthSnapshot().sessions[0].summaryEntries!
        XCTAssertEqual(saved.first { $0.id == b.id }, b)
        XCTAssertEqual(saved.first { $0.id == a.id }?.evidence?.careInstruction?.bucket, .carePlan)
        XCTAssertEqual(Set(saved.map(\.id)), Set([a.id, b.id]))
    }

    func testRepairRetainsConditionalWordingAndDoesNotRewriteOldTitle() throws {
        let entry = original()
        let repaired = try CarePlanOrganization.drafts(response(entry,
            headline: "If symptoms increase, call the clinic", bucket: "considerations"), originals: [entry])[0]
        XCTAssertEqual(repaired.evidence?.careInstruction?.instruction, "If symptoms increase, call the clinic")
        XCTAssertEqual(repaired.title, entry.title)
        XCTAssertEqual(repaired.details, entry.details)
        let rejected = SummaryCheck(id: repaired.id, supported: false, reason: "Original title remains unsupported", citations: [])
        let raw = try SummarySourceCheck.keyedResponse([rejected], expectedIDs: [repaired.id])
        XCTAssertEqual(try CarePlanOrganization.assessedDrafts(raw, drafts: [repaired], source: source)[0].evidence?.assessment?.admission, .sourceOnly)
    }

}
