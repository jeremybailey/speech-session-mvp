import XCTest
@testable import SpeechSessionPersistence
final class LocalArchiveReplayTests: XCTestCase {
 func testPreviouslySuppliedArchive() async throws {
  guard let path=ProcessInfo.processInfo.environment["CC_REPLAY_ZIP"],let password=ProcessInfo.processInfo.environment["CC_REPLAY_PASSWORD"] else {throw XCTSkip("Local replay only")}
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let store=try SessionStore(storageDirectory:root)
  let prepared=try await store.prepareDataImport(from:URL(fileURLWithPath:path),password:password)
  XCTAssertFalse(prepared.manifest.records.isEmpty)
 }
}
