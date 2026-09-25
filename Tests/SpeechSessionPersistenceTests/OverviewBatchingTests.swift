import XCTest
@testable import SpeechSessionPersistence

final class OverviewBatchingTests: XCTestCase {
    func testLargeUnicodeHistoryIsFullyPartitioned() {
        let source = String(repeating: "A dated concern 👩🏽‍⚕️ followed by treatment.\n", count: 5000)
        for limit in [5000, 24000] {
            let chunks = OverviewInputBatching.chunks(source, limit: limit)
            XCTAssertGreaterThan(chunks.count, 1)
            XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= limit })
            XCTAssertEqual(chunks.joined(), source)
        }
    }

    func testOverviewProseDoesNotRequireModelCitations() throws {
        let prose = try OverviewResponseContract.decodeProse(#"{"text":"You discussed fatigue during your visit."}"#)
        let entry = SummaryEntry(category: .symptoms, title: "Fatigue", origin: .userAdded)
        let fact = HealthFact(id: "saved-fact", occurrences: [entry], preference: .init(id: "saved-fact"), topicIDs: [])
        let overview = StoryOverview(text: prose, facts: [fact])
        XCTAssertTrue(overview.hasValidReferences(in: [fact]))
        XCTAssertFalse(overview.hasValidReferences(in: []))
        XCTAssertThrowsError(try OverviewResponseContract.decodeProse(#"{"text":"  "}"#))
    }

    func testIncompleteTranscriptionIsNotAutomaticallySummarized() {
        var session = Session(transcript: "Only the beginning of a visit")
        session.processingState = .failed
        XCTAssertFalse(session.needsSummaryVerification)
        session.processingState = .transcribing
        XCTAssertFalse(session.needsSummaryVerification)
        session.processingState = .ready
        XCTAssertTrue(session.needsSummaryVerification)
    }
}
