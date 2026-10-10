import XCTest
@testable import SpeechSessionPersistence

final class ConditionSourceContextTests: XCTestCase {
    func testRecordOpeningRetainsDistantReferralWithoutBorrowingOrInventingEvidence() throws {
        let source = Session(transcript: "Referred to this program for the ankle injury. " + String(repeating: "Original source context. ", count: 200) + "Return to this program in two weeks.")
        let other = Session(transcript: "Referred for an unrelated dental concern. Return to this program in two weeks.")
        let value = fact(source, quote: "Return to this program in two weeks.")
        let nearby = ConditionSourceContext.windows(facts: [value], sessions: [source])
        XCTAssertFalse(nearby[value.latest.id]!.contains { $0.contains("Referred") })
        let windows = ConditionSourceContext.windows(facts: [value], sessions: [other, source], includeRecordOpening: true)
        let slices = try XCTUnwrap(windows[value.latest.id])
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices.first?.count, 1_800)
        XCTAssertTrue(slices.allSatisfy { source.transcript.contains($0) && $0.count <= 1_800 })
        XCTAssertFalse(slices.joined().contains("dental"))
        XCTAssertTrue(slices.joined().contains("ankle injury"))
        XCTAssertTrue(ConditionSourceContext.windows(facts: [value], sessions: [other], includeRecordOpening: true).isEmpty)
        XCTAssertTrue(ConditionSourceContext.windows(facts: [fact(source, quote: "This quotation is absent from the record.")], sessions: [source], includeRecordOpening: true).isEmpty)
        let short = Session(transcript: "This program treats the ankle injury. Return to this program in two weeks.")
        let shortValue = fact(short, quote: "Return to this program in two weeks.")
        XCTAssertEqual(ConditionSourceContext.windows(facts: [shortValue], sessions: [short], includeRecordOpening: true)[shortValue.latest.id], [short.transcript])
    }
    private func fact(_ session: Session, quote: String) -> HealthFact {
        var entry = SummaryEntry(category: .followUp, title: "Follow-up", sourceSessionID: session.id)
        entry.sourceExcerpt = quote
        return HealthFact(id: entry.id.uuidString, occurrences: [entry], preference: .init(id: entry.id.uuidString), topicIDs: [])
    }

    func testRestoresOriginalCareExchangeWithoutBorrowingAnotherRecord() throws {
        let source = Session(transcript: "We are checking your ankle injury. Come back in two weeks. We will reassess the ankle then.")
        let other = Session(transcript: "For the dental treatment: Come back in two weeks.")
        let value = fact(source, quote: "Come back in two weeks.")
        let windows = ConditionSourceContext.windows(facts: [value], sessions: [other, source])
        XCTAssertEqual(windows[value.latest.id], [source.transcript])
        XCTAssertTrue(ConditionSourceContext.windows(facts: [value], sessions: [other]).isEmpty)
        let raw = try ConditionSynthesis.conditionWorkflowInput(plan: .init(preserved: .init(groups: [], unassigned: []), candidates: [value]), facts: [value], sourceWindows: windows)
        XCTAssertTrue(raw.contains("reassess the ankle"))
        XCTAssertFalse(raw.contains("dental"))
    }

    func testRepeatedMissingAndTooShortAnchorsDoNotInventContext() {
        let source = Session(transcript: "Come back in two weeks. Other episode. Come back in two weeks. Okay.")
        for quote in ["Come back in two weeks.", "A quotation that is absent.", "Okay."] {
            XCTAssertTrue(ConditionSourceContext.windows(facts: [fact(source, quote: quote)], sessions: [source]).isEmpty)
        }
    }

    func testWhitespaceMatchingPreservesVerbatimSourceAndBoundedWindows() throws {
        let text = String(repeating: "前", count: 1000) + "Care follow-up\nfor this ankle injury." + String(repeating: "後", count: 1000)
        let source = Session(transcript: text), value = fact(source, quote: "Care follow-up for this ankle injury.")
        let windows = ConditionSourceContext.windows(facts: [value], sessions: [source])
        let window = try XCTUnwrap(windows[value.latest.id]?.first)
        XCTAssertTrue(text.contains(window))
        XCTAssertTrue(window.contains("follow-up\nfor"))
        XCTAssertLessThanOrEqual(window.count, 1080)
        let batch = try ConditionSynthesis.batches([value], byteLimit: 24_000, sourceWindows: windows)
        XCTAssertEqual(batch.count, 1)
        XCTAssertThrowsError(try ConditionSynthesis.batches([value], byteLimit: 1000, sourceWindows: windows))
    }

    func testIndependentVerifierReceivesTheSameOriginalWindow() async throws {
        let source = Session(transcript: "We are checking your ankle injury. Come back in two weeks.")
        let value = fact(source, quote: "Come back in two weeks.")
        let windows = ConditionSourceContext.windows(facts: [value], sessions: [source])
        let proposal = ConditionSynthesis(groups: [.init(name: "Ankle injury", bodySystem: "musculoskeletal", isPrimary: false, reason: "A mapper rationale", entryIDs: [value.latest.id])], unassigned: [])
        let checked = try await ConditionSynthesis.verified(proposal, facts: [value], sourceWindows: windows) { input in
            XCTAssertTrue(input.contains("checking your ankle injury"))
            XCTAssertFalse(input.contains("A mapper rationale"))
            return "{\"decisions\":[{\"name\":\"Ankle injury\",\"bodySystem\":\"musculoskeletal\",\"nameSupported\":true,\"supportedEntryIDs\":[\"\(value.latest.id)\"],\"reason\":\"Explicit care episode\"}]}"
        }
        XCTAssertEqual(checked.groups.first?.entryIDs, [value.latest.id])
    }
}
