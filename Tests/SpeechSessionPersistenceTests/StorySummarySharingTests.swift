import XCTest
import PDFKit
@testable import SpeechSessionPersistence

final class StorySummarySharingTests: XCTestCase {
    func testSensitivePhrasesAndOrdinaryCare() {
        for text in ["Safety — no concerns", "Denies suicidal ideation", "Self-harm screening negative", "Thoughts of hurting herself", "Intrusive harm visions", "Painful intercourse", "Low libido", "Vulvar varicosities", "Perineal sensation reduced", "Groin varicosities", "Pelvic numbness", "Vaginal pain"] {
            XCTAssertTrue(StorySummarySharing.isSensitive(text), text)
        }
        for text in ["Vaginal delivery after induction", "Pelvic floor physiotherapy", "Urinary frequency", "Migraine attacks limit activity", "Depression treated with counselling", "Pregnancy at 30 weeks", "SI joint pain"] {
            XCTAssertFalse(StorySummarySharing.isSensitive(text), text)
        }
    }

    func testFiltersWholePointsNestedSectionsAndContinuationRows() {
        let blocks: [StorySummaryBlock] = [
            .heading("Clinical Snapshot", level: 2),
            .bullet("Migraine — weekly attacks"), .bullet("Sexual function — pain; also fatigue"),
            .heading("Safety screening", level: 3), .bullet("No concerns reported"),
            .heading("History", level: 2),
            .table(headers: ["Topic", "Notes"], rows: [["Sexual function", "Pain"], ["", "Improved"], ["Migraine", "Improved"]]),
            .heading("Care plan", level: 2), .bullet("Perineal massage — discussed")
        ]
        XCTAssertEqual(StorySummarySharing.excludingSensitiveDetails(blocks), [
            .heading("Clinical Snapshot", level: 2), .bullet("Migraine — weekly attacks"),
            .heading("History", level: 2), .table(headers: ["Topic", "Notes"], rows: [["Migraine", "Improved"]])
        ])
    }

    func testPDFContainsOnlySelectedContentAndOriginalIsUnchanged() throws {
        let text = """
        ## Clinical Snapshot
        - Migraine — weekly attacks
        - Safety — denies suicidal thoughts
        ## Comprehensive Health History
        - Birth — vaginal delivery
        - Sexual function — painful intercourse
        ## Care Plan & Interventions
        - Pelvic floor — physiotherapy ongoing
        - Perineal massage — discussed
        """
        let date = Date(timeIntervalSince1970: 1795478400)
        let filtered = try StorySummaryPDF.render(text: text, title: "Practitioner summary", generatedAt: date, excludeSensitiveDetails: true)
        let full = try StorySummaryPDF.render(text: text, title: "Practitioner summary", generatedAt: date, excludeSensitiveDetails: false)
        let filteredText = try XCTUnwrap(PDFDocument(data: filtered)?.string).lowercased()
        let fullText = try XCTUnwrap(PDFDocument(data: full)?.string).lowercased()
        for word in ["suicidal", "intercourse", "perineal"] { XCTAssertFalse(filteredText.contains(word)); XCTAssertTrue(fullText.contains(word)) }
        for word in ["migraine", "vaginal delivery", "physiotherapy"] { XCTAssertTrue(filteredText.contains(word), word) }
        XCTAssertTrue(text.contains("painful intercourse"))
        try filtered.write(to: URL(fileURLWithPath: "/tmp/cc-sharing-filtered.pdf"))
        try full.write(to: URL(fileURLWithPath: "/tmp/cc-sharing-full.pdf"))
    }

    func testPreferencePersistsWithoutChangingRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let record = Session(transcript: "Synthetic sensitive source: painful intercourse")
        try await store.upsert(record)
        try await store.setPractitionerExcludeSensitiveDetails(false)
        let reopened = try SessionStore(storageDirectory: directory)
        let preference = try await reopened.storyWorkspace().practitionerExcludeSensitiveDetails
        XCTAssertEqual(preference, false)
        let records = try await reopened.healthSnapshot().sessions
        XCTAssertEqual(records.first?.transcript, record.transcript)
        try await reopened.setPractitionerExcludeSensitiveDetails(true)
        let updated = try await reopened.storyWorkspace().practitionerExcludeSensitiveDetails
        XCTAssertEqual(updated, true)
    }

    func testLegacyWorkspaceDefaultsToExclusion() throws {
        let workspace = StoryWorkspace()
        XCTAssertTrue(workspace.practitionerExcludeSensitiveDetails ?? true)
        var optedIn = workspace
        optedIn.practitionerExcludeSensitiveDetails = false
        let restored = try JSONDecoder().decode(StoryWorkspace.self, from: JSONEncoder().encode(optedIn))
        XCTAssertEqual(restored.practitionerExcludeSensitiveDetails, false)
    }
    func testSafetyPhrasesWithPossessivesAndDirectionalWordingAreExcluded() {
        for text in ["Thoughts of harming her baby", "No thoughts of hurting my children", "Thoughts of harm towards others", "Thoughts of killing their own infant"] {
            XCTAssertTrue(StorySummarySharing.isSensitive(text), text)
        }
        for text in ["Baby aspirin discussed", "Mother and baby doing well", "Nocturnal reflux", "Hip pain after lifting her baby"] {
            XCTAssertFalse(StorySummarySharing.isSensitive(text), text)
        }
    }

    @MainActor func testPractitionerRendererDefaultsToSensitiveExclusion() throws {
        let summary = StorySharedSummary(templateID: "practitioner-v1", text: "## Clinical Snapshot\n- Migraine — weekly attacks\n- Safety — suicidal thoughts denied", evidence: [])
        let filtered = try StorySummaryPDF.renderSummary(summary, title: "Practitioner summary", patientName: nil)
        let full = try StorySummaryPDF.renderSummary(summary, title: "Practitioner summary", patientName: nil, excludeSensitiveDetails: false)
        XCTAssertFalse(try XCTUnwrap(PDFDocument(data: filtered)?.string).contains("suicidal"))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: full)?.string).contains("suicidal"))
        XCTAssertTrue(summary.text.contains("suicidal"))
    }

}
