import XCTest
@testable import SpeechSessionPersistence

final class UserProfileTests: XCTestCase {
    func testProfilesPersistAndAccountsIncludingSignedOutStaySeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UserProfileStore(directory: directory)
        try await store.save(UserProfile(name: "  Example Person  ", photoData: Data([1,2,3])), accountID: "account/one")
        try await store.save(UserProfile(name: "Other Person"), accountID: "account-two")
        let reopened = UserProfileStore(directory: directory)
        let first = try await reopened.load(accountID: "account/one")
        let second = try await reopened.load(accountID: "account-two")
        let guest = try await reopened.load(accountID: nil)
        XCTAssertEqual(first.name, "Example Person")
        XCTAssertEqual(first.photoData, Data([1,2,3]))
        XCTAssertEqual(second.name, "Other Person")
        XCTAssertEqual(guest, UserProfile())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.count == 69 && !$0.contains("account") })
        try await reopened.save(UserProfile(name: first.name), accountID: "account/one")
        let removed = try await reopened.load(accountID: "account/one")
        XCTAssertNil(removed.photoData)
    }

    func testSignInSeedsNameButNeverOverwritesAnEditOrExplicitlyClearedName() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UserProfileStore(directory: directory)
        try await store.seedName("Apple Name", accountID: "one")
        let seeded = try await store.load(accountID: "one")
        XCTAssertEqual(seeded.name, "Apple Name")
        try await store.save(UserProfile(name: "Chosen Name"), accountID: "one")
        try await store.seedName("Provider Changed Name", accountID: "one")
        let edited = try await store.load(accountID: "one")
        XCTAssertEqual(edited.name, "Chosen Name")
        try await store.save(UserProfile(name: ""), accountID: "one")
        try await store.seedName("Apple Name", accountID: "one")
        let cleared = try await store.load(accountID: "one")
        XCTAssertEqual(cleared.name, "")
        XCTAssertTrue(cleared.nameEdited)
    }

    func testOversizedPhotoCannotReplaceSavedProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UserProfileStore(directory: directory)
        try await store.save(UserProfile(name: "Original"), accountID: "one")
        do {
            try await store.save(UserProfile(name: "Replacement", photoData: Data(repeating: 1, count: UserProfileStore.maximumPhotoBytes + 1)), accountID: "one")
            XCTFail("Oversized photo accepted")
        } catch UserProfileError.invalidProfile { }
        let preserved = try await store.load(accountID: "one")
        XCTAssertEqual(preserved.name, "Original")
    }
}
