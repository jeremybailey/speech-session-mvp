import XCTest
import SpeechSessionPersistence

final class SessionStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testLoadAll_missingFile_returnsEmpty() async throws {
        let store = try SessionStore(storageDirectory: tempDir)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testUpsert_insert_sortsNewestFirst() async throws {
        let store = try SessionStore(storageDirectory: tempDir)
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let s1 = Session(date: older, transcript: "a")
        let s2 = Session(date: newer, transcript: "b")
        try await store.upsert(s1)
        try await store.upsert(s2)
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].transcript, "b")
        XCTAssertEqual(loaded[1].transcript, "a")
    }

    func testUpsert_replaceSameId() async throws {
        let store = try SessionStore(storageDirectory: tempDir)
        let id = UUID()
        try await store.upsert(Session(id: id, date: Date(), transcript: "first"))
        try await store.upsert(Session(id: id, date: Date(), transcript: "second"))
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].transcript, "second")
    }

    func testSave_roundTrip_preservesVersionAndDates() async throws {
        let store = try SessionStore(storageDirectory: tempDir)
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let original = [Session(date: date, transcript: "hello")]
        try await store.save(original)
        let fileURL = tempDir.appendingPathComponent(SessionStore.sessionsFileName)
        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].transcript, "hello")
        XCTAssertEqual(loaded[0].date.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAtomicWrite_replacesExistingFile() async throws {
        let store = try SessionStore(storageDirectory: tempDir)
        try await store.save([Session(transcript: "v1")])
        try await store.save([Session(transcript: "v2")])
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].transcript, "v2")
    }
}
