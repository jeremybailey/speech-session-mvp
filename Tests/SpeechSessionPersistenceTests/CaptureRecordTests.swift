import XCTest
@testable import SpeechSessionPersistence

final class CaptureRecordTests: XCTestCase {
    func testSummaryRevisionSurvivesRawEditsAndRejectsAStaleSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let record = Session(transcript: "Original passage")
        try await store.upsert(record)
        try await store.saveRecordSummary(record.id, changes: ["detail": "Edited paragraph"], baseline: [:], title: "My note")
        let saved = try await store.loadAll()
        XCTAssertEqual(saved.first?.transcript, "Original passage")
        do {
            try await store.saveRecordSummary(record.id, changes: ["detail": "Stale edit"], baseline: [:], title: nil)
            XCTFail("Stale edits should be rejected")
        } catch StoryEditError.staleRevision {}
        try await store.reviseStorySource(record.id, text: "Corrected passage", expectedTranscript: record.transcript)
        let reopened = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let records = try await reopened.loadAll()
        XCTAssertEqual(records.first?.summaryParagraphEdits, ["detail": "Edited paragraph"])
        XCTAssertEqual(records.first?.displayTitle, "My note")
        XCTAssertEqual(records.first?.transcript, "Corrected passage")
    }

    func testPartialCaptureRetryAndTitleAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let audio = SessionSourceAsset(kind: .audio, relativePath: "audio.caf", displayName: "Recording 1")
        let photo = SessionSourceAsset(kind: .image, relativePath: "photo.jpg", displayName: "Photo 1")
        var record = Session(transcript: "", sourceAssets: [audio, photo])
        var capture = RecordCapture()
        capture.patientTitle = "My visit"
        capture.notes = "Question about sleep"
        capture.isDraft = false
        capture.pending = true
        record.capture = capture
        try await store.upsert(record)
        try await store.checkpointCapture(id: record.id, asset: audio.id, text: "Visit transcript", publish: false)
        try await store.checkpointCapture(id: record.id, asset: photo.id, text: nil, publish: true)
        let saved = try await store.loadAll()
        XCTAssertEqual(saved.first?.capture?.failedAssets, [photo.id])
        XCTAssertTrue(saved.first?.transcript.contains("Patient notes\nQuestion about sleep") == true)
        XCTAssertTrue(saved.first?.transcript.contains("Recording 1\nVisit transcript") == true)
        let member = CareTeamMember(name: "Test clinician")
        try await store.saveCareTeamMember(member)
        let visit = Date(timeIntervalSince1970: 1000000)
        try await store.editRecordMetadata(id: record.id, title: "Edited visit", time: visit, members: [member.id])
        try await store.reviseStorySource(record.id, text: "Corrected speech", expectedTranscript: saved.first!.transcript)
        let reopened = try SessionStore(storageDirectory: directory)
        try await reopened.checkpointCapture(id: record.id, asset: photo.id, text: "Label text", publish: true)
        try await reopened.checkpointCapture(id: record.id, asset: photo.id, text: "Label text", publish: true)
        let final = try await reopened.loadAll()
        XCTAssertEqual(final.map(\.id), [record.id])
        XCTAssertEqual(final.first?.displayTitle, "Edited visit")
        XCTAssertEqual(final.first?.capture?.patientTitle, "My visit")
        XCTAssertEqual(final.first?.visitTime, visit)
        XCTAssertEqual(final.first?.linkedMemberIDs, [member.id])
        XCTAssertEqual(final.first?.transcript, "Corrected speech\n\nPhoto 1\nLabel text")
        XCTAssertEqual(final.first?.capture?.textByAsset[audio.id], "Visit transcript")
        XCTAssertEqual(final.first?.capture?.failedAssets, [])
        XCTAssertEqual(final.first?.transcript.components(separatedBy: "Label text").count, 2)
    }
}
