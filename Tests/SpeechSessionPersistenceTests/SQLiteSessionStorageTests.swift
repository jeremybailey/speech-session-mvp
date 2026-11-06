import XCTest
@testable import SpeechSessionPersistence
final class SQLiteSessionStorageTests: XCTestCase {
    func testMigrationRoundTripAndImportCacheRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let original = Session(date:Date(timeIntervalSince1970:1000),transcript:"Original record text")
        let json = try SessionStore(storageDirectory:root)
        try await json.save([original])
        let sqlite = try SessionStore(storageDirectory:root,sqliteEnabled:true)
        let imported = try await sqlite.loadAll()
        XCTAssertEqual(imported,[original])
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("pre-sqlite-sessions.json").path))
        var changed = original; changed.transcript = "Patient correction"
        try await sqlite.upsert(changed)
        let reopened = try SessionStore(storageDirectory:root)
        let actual = try await reopened.loadAll()
        XCTAssertEqual(actual,[changed])
        try await reopened.delete(id:original.id)
        let afterDelete = try await SessionStore(storageDirectory:root).loadAll()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testRowsPreserveEditsAndInvalidTransactionRollsBack() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        var session=Session(date:Date(timeIntervalSince1970:1000),transcript:"Original")
        var entry=SummaryEntry(category:.medications,title:"My correction")
        entry.origin = .userEdited
        session.summaryEntries=[entry]
        session.summaryRevisions=[SummaryRevision(runID:UUID(),entries:[entry])]
        session.summaryRun=SummaryRun(source:session.transcript)
        var envelope=SessionsEnvelope(sessions:[session])
        envelope.recordUpdate=RecordUpdateReceipt(sources:[session.id.uuidString:"hash"])
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let data=try encoder.encode(envelope),storage=SQLiteSessionStorage(directory:root)
        try storage.save(data)
        let actual=try XCTUnwrap(storage.load())
        XCTAssertEqual(try decoder.decode(SessionsEnvelope.self,from:actual),try decoder.decode(SessionsEnvelope.self,from:data))
        envelope.sessions.append(session)
        XCTAssertThrowsError(try storage.save(encoder.encode(envelope)))
        XCTAssertEqual(try storage.load(),actual)
    }
}
