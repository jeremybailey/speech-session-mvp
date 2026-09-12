import XCTest
import SpeechSessionPersistence

final class SummaryEntryMergeTests: XCTestCase {
    func testNormalizedFactKey_collapsesSpacingAndCase() {
        XCTAssertEqual(SummaryEntry.normalizedFactKey("Migraine Aura"), "migraine-aura")
        XCTAssertEqual(SummaryEntry.normalizedFactKey("  METFORMIN  "), "metformin")
        XCTAssertNil(SummaryEntry.normalizedFactKey("   "))
    }

    func testParseClinicalStatus_acceptsPromptWording() {
        XCTAssertEqual(SummaryEntryClinicalStatus.parse("current"), .current)
        XCTAssertEqual(SummaryEntryClinicalStatus.parse("Past"), .past)
        XCTAssertEqual(SummaryEntryClinicalStatus.parse("resolved"), .past)
        XCTAssertNil(SummaryEntryClinicalStatus.parse("maybe"))
    }

    func testMerge_keepsUserEditedContentAndStatus() {
        let existingID = UUID()
        let existing = SummaryEntry(
            id: existingID,
            category: .symptoms,
            title: "Migraine (user wording)",
            details: "user kept this",
            origin: .userEdited,
            clinicalStatus: .past,
            factKey: "migraine"
        )
        let generated = SummaryEntry(
            category: .symptoms,
            title: "Migraine",
            details: "photophobia",
            origin: .generated,
            clinicalStatus: .current,
            factKey: "migraine"
        )

        let merged = SummaryEntryMerge.merging(generated: [generated], existing: [existing])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existingID)
        XCTAssertEqual(merged[0].title, "Migraine (user wording)")
        XCTAssertEqual(merged[0].details, "user kept this")
        XCTAssertEqual(merged[0].clinicalStatus, .past)
        XCTAssertEqual(merged[0].origin, .userEdited)
        XCTAssertEqual(merged[0].factKey, "migraine")
    }

    func testMerge_keepsUserAddedCards() {
        let userAdded = SummaryEntry(
            category: .otherNotes,
            title: "Family history",
            details: "mother had migraines",
            origin: .userAdded
        )
        let generated = SummaryEntry(
            category: .symptoms,
            title: "Nausea",
            origin: .generated,
            factKey: "nausea"
        )

        let merged = SummaryEntryMerge.merging(generated: [generated], existing: [userAdded])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(where: { $0.origin == .userAdded && $0.title == "Family history" }))
        XCTAssertTrue(merged.contains(where: { $0.factKey == "nausea" }))
    }

    func testMerge_keepsDeletedTombstonesMatchedByFactKey() {
        let existingID = UUID()
        var deleted = SummaryEntry(
            id: existingID,
            category: .medications,
            title: "Ibuprofen",
            isDeleted: true,
            origin: .userEdited,
            factKey: "ibuprofen"
        )
        deleted.isDeleted = true
        let generated = SummaryEntry(
            category: .medications,
            title: "Ibuprofen",
            details: "200 mg PRN",
            origin: .generated,
            factKey: "ibuprofen"
        )

        let merged = SummaryEntryMerge.merging(generated: [generated], existing: [deleted])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existingID)
        XCTAssertTrue(merged[0].isDeleted)
    }

    func testMerge_replacesUnmatchedGeneratedCards() {
        let stale = SummaryEntry(
            category: .symptoms,
            title: "Old leftover",
            origin: .generated
        )
        let generated = SummaryEntry(
            category: .symptoms,
            title: "Nausea",
            origin: .generated,
            factKey: "nausea"
        )

        let merged = SummaryEntryMerge.merging(generated: [generated], existing: [stale])
        XCTAssertEqual(merged.map(\.title), ["Nausea"])
    }

    func testMerge_matchesByTitleWhenFactKeyMissing() {
        let existingID = UUID()
        let existing = SummaryEntry(
            id: existingID,
            category: .findings,
            title: "Hypertension",
            details: "old",
            origin: .generated
        )
        let generated = SummaryEntry(
            category: .findings,
            title: "Hypertension",
            details: "new reading",
            origin: .generated,
            clinicalStatus: .current
        )

        let merged = SummaryEntryMerge.merging(generated: [generated], existing: [existing])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existingID)
        XCTAssertEqual(merged[0].details, "new reading")
    }

    func testSummaryEntry_roundTripsFactKey() throws {
        let entry = SummaryEntry(
            category: .chiefComplaint,
            title: "Migraine",
            clinicalStatus: .current,
            factKey: "Migraine Aura"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SummaryEntry.self, from: data)
        XCTAssertEqual(decoded.factKey, "migraine-aura")
        XCTAssertEqual(decoded.clinicalStatus, .current)
    }
}
