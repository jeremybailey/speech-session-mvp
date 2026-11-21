import XCTest
@testable import SpeechSessionPersistence

final class RecordMetadataSaveTests: XCTestCase {
    func testLocalEditsPreserveHistoryAfterReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let records = (0..<30).map { _ in
            let id = UUID()
            return Session(id: id, transcript: "Synthetic note", summaryEntries: (0..<20).map {
                SummaryEntry(category: .symptoms, title: "Symptom \($0)", sourceSessionID: id, origin: .userAdded)
            })
        }
        try await store.save(records)
        let id = records[0].id
        let folder = SessionFolder(name: "Condition")
        let contact = CareTeamMember(name: "Example")
        let time = Date(timeIntervalSince1970: 10000)
        let start = Date()
        try await store.setRecordFolders(recordID: id, folders: [folder])
        let filed = Date()
        try await store.saveCareTeamMember(contact)
        let added = Date()
        try await store.editRecordMetadata(id: id, time: time, members: [contact.id])
        print("SAVE_AUDIT folder=\(Int(filed.timeIntervalSince(start)*1000)) contact=\(Int(added.timeIntervalSince(filed)*1000)) metadata=\(Int(Date().timeIntervalSince(added)*1000))")
        let reopened = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let snapshot = try await reopened.healthSnapshot()
        let record = try XCTUnwrap(snapshot.sessions.first { $0.id == id })
        XCTAssertEqual(record.selectedFolderIDs, [folder.id])
        XCTAssertEqual(record.linkedMemberIDs, [contact.id])
        XCTAssertEqual(record.visitTime, time)
        XCTAssertEqual(snapshot.careTeam.first?.id, contact.id)
        XCTAssertEqual(record.summaryEntries?.count, 20)
        XCTAssertEqual(snapshot.sessions.count, 30)
    }
}
