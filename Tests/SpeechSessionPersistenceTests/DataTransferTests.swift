import XCTest
import ZipArchive
@testable import SpeechSessionPersistence

final class DataTransferTests: XCTestCase {
    var root: URL!
    let password = "synthetic-test-password"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func fixture(_ name: String) async throws -> (SessionStore, Session, URL) {
        let directory = root.appendingPathComponent(name)
        let store = try SessionStore(storageDirectory: directory)
        var session = Session(date: Date(timeIntervalSince1970: 1000), transcript: "Synthetic source\nExact spacing  and Unicode ×3.\n", title: "Private synthetic title")
        var entry = SummaryEntry(category: .carePlan, title: "Synthetic exercise", details: "Three times.", origin: .userEdited)
        entry.sourceSessionID = session.id; entry.sourceExcerpt = "Unicode ×3."
        entry.createdAt = session.date; entry.updatedAt = session.date
        session.summaryEntries = [entry]; session.summary = "Saved summary"
        session.summaryRun = SummaryRun(source: session.transcript, stage: .interrupted)
        let source = SessionSourceStore(storageDirectory: directory)
        session.sourceAssets = [try source.saveData(Data("fake original".utf8), sessionID: session.id,
                                                   fileName: "private-name.txt", displayName: "Private name", kind: .plainText)]
        session.sourceAssets?[0].createdAt = session.date
        try await store.upsert(session)
        // Must never be included, even though these files are beside the records.
        try Data("not-an-actual-credential".utf8).write(to: directory.appendingPathComponent("credentials.json"))
        try Data("stale job".utf8).write(to: directory.appendingPathComponent("condition-synthesis-progress.json"))
        return (store, session, directory)
    }

    func testTextOnlyRoundTripKeepsIDsAndTextWithoutOriginalsOrCheckpoints() async throws {
        let (source, session, _) = try await fixture("source")
        let zip = try await source.exportData(password: password, includeOriginals: false, appVersion: "test")
        XCTAssertTrue(SSZipArchive.isFilePasswordProtected(atPath: zip.path))
        let destination = try SessionStore(storageDirectory: root.appendingPathComponent("destination"))
        let prior = Session(transcript: "Old person's data")
        try await destination.upsert(prior)
        let prepared = try await destination.prepareDataImport(from: zip, password: password)
        XCTAssertEqual(prepared.manifest.records.map(\.id), [session.id])
        XCTAssertFalse(prepared.manifest.includesOriginals)
        XCTAssertFalse(prepared.manifest.files.contains { $0.destination.contains("credentials") || $0.destination.contains("progress") || $0.destination.hasPrefix("sources/") })
        XCTAssertTrue(prepared.manifest.files.allSatisfy { UUID(uuidString: $0.archiveName) != nil })
        try await destination.replaceWithImportedData(prepared)
        let imported = try await destination.loadAll()
        XCTAssertEqual(imported.count, 1); XCTAssertEqual(imported[0].id, session.id)
        XCTAssertEqual(imported[0].transcript, session.transcript)
        XCTAssertEqual(imported[0].summaryEntries, session.summaryEntries)
        XCTAssertEqual(imported[0].sourceAssets, session.sourceAssets)
        XCTAssertNil(imported[0].summaryRun)
        let importedPolicy = await destination.isImportedHistory
        XCTAssertTrue(importedPolicy)
        let reopened = try SessionStore(storageDirectory: root.appendingPathComponent("destination"))
        let restoredPolicy = await reopened.isImportedHistory
        XCTAssertTrue(restoredPolicy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("destination/sources").path))
    }

    func testFullExportRestoresOriginalAndReplacesPreviousFiles() async throws {
        let (source, session, _) = try await fixture("source")
        let (destination, previous, destinationURL) = try await fixture("destination")
        let backup = try await destination.exportData(password: password, includeOriginals: true, appVersion: "test")
        let savedBackup = root.appendingPathComponent("backup.zip")
        try FileManager.default.copyItem(at: backup, to: savedBackup)
        let zip = try await source.exportData(password: password, includeOriginals: true, appVersion: "test")
        let prepared = try await destination.prepareDataImport(from: zip, password: password)
        try await destination.replaceWithImportedData(prepared)
        let sources = SessionSourceStore(storageDirectory: destinationURL)
        XCTAssertEqual(try Data(contentsOf: sources.url(for: session.sourceAssets![0], sessionID: session.id)), Data("fake original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sources.sessionSourcesDirectory(sessionID: previous.id).path))
        let restore = try await destination.prepareDataImport(from: savedBackup, password: password)
        try await destination.replaceWithImportedData(restore)
        let loaded = try await destination.loadAll()
        XCTAssertEqual(loaded.map(\.id), [previous.id])
        XCTAssertEqual(try Data(contentsOf: sources.url(for: previous.sourceAssets![0], sessionID: previous.id)), Data("fake original".utf8))
    }

    func testWrongPasswordAndCorruptionLeaveCurrentHistoryUntouched() async throws {
        let (source, _, _) = try await fixture("source")
        let (destination, existing, _) = try await fixture("destination")
        let zip = try await source.exportData(password: password, includeOriginals: false, appVersion: "test")
        do { _ = try await destination.prepareDataImport(from: zip, password: "wrong"); XCTFail("Accepted wrong password") } catch {}
        let bad = root.appendingPathComponent("corrupt.zip")
        try Data("not a zip".utf8).write(to: bad)
        do { _ = try await destination.prepareDataImport(from: bad, password: password); XCTFail("Accepted corruption") } catch {}
        let loaded = try await destination.loadAll()
        XCTAssertEqual(loaded.map(\.id), [existing.id])
    }

    func testMissingOriginalsRequireExplicitAcknowledgement() async throws {
        let (store, session, directory) = try await fixture("source")
        try SessionSourceStore(storageDirectory: directory).deleteSources(for: session.id)
        do { _ = try await store.exportData(password: password, includeOriginals: true, appVersion: "test"); XCTFail("Silently omitted original") }
        catch DataTransferError.missingOriginals(let count) { XCTAssertEqual(count, 1) }
        let zip = try await store.exportData(password: password, includeOriginals: true, allowMissingOriginals: true, appVersion: "test")
        let dest = try SessionStore(storageDirectory: root.appendingPathComponent("dest"))
        let result = try await dest.prepareDataImport(from: zip, password: password)
        XCTAssertEqual(result.manifest.missingOriginalCount, 1)
    }

    func testInterruptedReplacementRestoresOldStoreBeforeOpening() async throws {
        let (_, session, directory) = try await fixture("source")
        try FileManager.default.moveItem(at: directory, to: DataTransferArchive.rollbackRoot(directory))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial new data".utf8).write(to: directory.appendingPathComponent("sessions.json"))
        let recovered = try SessionStore(storageDirectory: directory)
        let sessions = try await recovered.loadAll()
        XCTAssertEqual(sessions.map(\.id), [session.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: DataTransferArchive.rollbackRoot(directory).path))
    }

    func testUnsafeArchivePathsAndUnencryptedArchivesAreRejected() async throws {
        let store = try SessionStore(storageDirectory: root.appendingPathComponent("dest"))
        for (name, secret) in [("../escape", password), ("manifest.json", "")] {
            let zip = root.appendingPathComponent(UUID().uuidString + ".zip")
            let writer = SSZipArchive(path: zip.path); XCTAssertTrue(writer.open())
            XCTAssertTrue(writer.write(Data("test".utf8), filename: name, compressionLevel: -1, password: secret.isEmpty ? nil : secret, aes: true))
            XCTAssertTrue(writer.close())
            do { _ = try await store.prepareDataImport(from: zip, password: password); XCTFail("Accepted unsafe archive") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }

    func testValidationRejectsDuplicateIDsAndBadReferences() throws {
        let session = Session(transcript: "synthetic")
        XCTAssertThrowsError(try DataTransferArchive.validateEnvelope(SessionsEnvelope(sessions: [session, session])))
        var invalid = session; invalid.folderID = UUID()
        XCTAssertThrowsError(try DataTransferArchive.validateEnvelope(SessionsEnvelope(sessions: [invalid])))
    }

    func testSpaceCheckFailsWithoutChangingData() throws {
        XCTAssertThrowsError(try DataTransferArchive.requireSpace(UInt64.max - 128 * 1024 * 1024, at: root))
    }

    func testPasswordGuidanceMatchesValidation() async throws {
        let (store, _, _) = try await fixture("source")
        do {
            _ = try await store.exportData(password: "short", includeOriginals: false, appVersion: "test")
            XCTFail("Accepted a short password")
        } catch DataTransferError.passwordTooShort {
            XCTAssertTrue(DataTransferError.passwordTooShort.localizedDescription.contains("12 characters"))
        }
        let words = "twelve chars"
        XCTAssertEqual(words.count, DataTransferArchive.minimumPasswordLength)
        let zip = try await store.exportData(password: words, includeOriginals: false, appVersion: "test")
        let destination = try SessionStore(storageDirectory: root.appendingPathComponent("dest"))
        _ = try await destination.prepareDataImport(from: zip, password: words)
    }

    func testArchiveLimitsAndFalseDeclaredSize() async throws {
        XCTAssertNoThrow(try DataTransferArchive.enforceLimit(count: 20_000, bytes: 5 * 1024 * 1024 * 1024))
        XCTAssertThrowsError(try DataTransferArchive.enforceLimit(count: 20_001, bytes: 0))
        XCTAssertThrowsError(try DataTransferArchive.enforceLimit(count: 1, bytes: 5 * 1024 * 1024 * 1024 + 1))
        let zip = root.appendingPathComponent("false-size.zip")
        let writer = SSZipArchive(path: zip.path)
        XCTAssertTrue(writer.open())
        XCTAssertTrue(writer.write(Data(repeating: 65, count: 100_000), filename: "manifest.json", compressionLevel: -1, password: password, aes: true))
        XCTAssertTrue(writer.close())
        var bytes = try Data(contentsOf: zip)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let header = try XCTUnwrap(bytes.range(of: signature)).lowerBound
        // Lie about the central directory's uncompressed size. The streaming
        // reader must stop before writing more than the declared byte allowance.
        bytes.replaceSubrange((header + 24)..<(header + 28), with: [1, 0, 0, 0])
        try bytes.write(to: zip)
        let destination = try SessionStore(storageDirectory: root.appendingPathComponent("dest"))
        do { _ = try await destination.prepareDataImport(from: zip, password: password); XCTFail("Accepted false size") } catch {}
    }

    func encryptedZIP(_ directory: URL) throws -> URL {
        let zip = root.appendingPathComponent(UUID().uuidString + ".zip")
        let writer = SSZipArchive(path: zip.path); XCTAssertTrue(writer.open())
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            XCTAssertTrue(writer.writeFile(atPath: directory.appendingPathComponent(name).path, withFileName: name,
                                           compressionLevel: -1, password: password, aes: true))
        }
        XCTAssertTrue(writer.close()); return zip
    }

    func testTamperedPayloadAndUnsupportedManifestRejectedBeforeReplacement() async throws {
        let (source, _, _) = try await fixture("source")
        let (destination, original, _) = try await fixture("destination")
        let zip = try await source.exportData(password: password, includeOriginals: false, appVersion: "test")
        let prepared = try await destination.prepareDataImport(from: zip, password: password)
        let payload = root.appendingPathComponent("tampered")
        try FileManager.default.copyItem(at: prepared.directory, to: payload)
        let record = prepared.manifest.records[0]
        try Data("edited text with wrong checksum".utf8).write(to: payload.appendingPathComponent(record.sourceTextFile))
        let tampered = try encryptedZIP(payload)
        do { _ = try await destination.prepareDataImport(from: tampered, password: password); XCTFail("Accepted bad checksum") } catch {}
        let manifestURL = payload.appendingPathComponent("manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        json["version"] = 1000
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        let future = try encryptedZIP(payload)
        do { _ = try await destination.prepareDataImport(from: future, password: password); XCTFail("Accepted future version") }
        catch DataTransferError.unsupportedVersion {}
        let loaded = try await destination.loadAll()
        XCTAssertEqual(loaded.map(\.id), [original.id])
    }

    func testCompletedCommitSurvivesInterruptedRollbackCleanup() async throws {
        let (store, session, directory) = try await fixture("source")
        let rollback = DataTransferArchive.rollbackRoot(directory)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        try Data("partially removed old history".utf8).write(to: rollback.appendingPathComponent("obsolete"))
        try Data("committed".utf8).write(to: DataTransferArchive.commitMarker(directory))
        _ = store
        let reopened = try SessionStore(storageDirectory: directory)
        let loaded = try await reopened.loadAll()
        XCTAssertEqual(loaded.map(\.id), [session.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollback.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DataTransferArchive.commitMarker(directory).path))
    }

    func testCancelledImportLeavesOldDataAndDeletesStaging() async throws {
        let (source, _, _) = try await fixture("source")
        let (destination, original, directory) = try await fixture("destination")
        let zip = try await source.exportData(password: password, includeOriginals: false, appVersion: "test")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await destination.prepareDataImport(from: zip, password: password)
        }
        do { _ = try await task.value; XCTFail("Ignored cancellation") } catch is CancellationError {}
        let loaded = try await destination.loadAll()
        XCTAssertEqual(loaded.map(\.id), [original.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: DataTransferArchive.workRoot(directory).path))
    }

    func testSymlinkOriginalCannotEscapeHistoryRoot() async throws {
        let (store, session, directory) = try await fixture("source")
        let sourceURL = SessionSourceStore(storageDirectory: directory).url(for: session.sourceAssets![0], sessionID: session.id)
        try FileManager.default.removeItem(at: sourceURL)
        let external = root.appendingPathComponent("outside.txt")
        try Data("outside file".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: external)
        let missing = try await store.missingOriginalCount()
        XCTAssertEqual(missing, 1)
        do { _ = try await store.exportData(password: password, includeOriginals: true, appVersion: "test"); XCTFail("Followed symlink") }
        catch DataTransferError.missingOriginals {}
    }

    func testAcceptedConditionsOverviewAndManualChoicesRoundTrip() async throws {
        let (store, _, _) = try await fixture("source")
        let snapshot = try await store.healthSnapshot()
        var facts = HealthMemoryProjection.facts(in: snapshot)
        XCTAssertFalse(facts.isEmpty)
        var preference = HealthFactPreference(id: facts[0].id)
        preference.reviewedRevision = "reviewed-test-version"
        try await store.savePreference(preference)
        facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
        let condition = ConditionSynthesis(groups: [.init(name: "Knee pain", bodySystem: "musculoskeletal", isPrimary: false,
                                                         reason: "Synthetic test mapping", entryIDs: facts.flatMap(\.occurrences).map(\.id))], unassigned: [])
        try await store.saveConditionSynthesis(condition, expected: facts)
        var overview = StoryOverview(text: "Synthetic saved overview.", facts: facts)
        overview.conditionContext = await store.currentOverviewConditionContext(facts)
        try await store.saveStoryOverview(overview, expected: facts)
        let originalMapping = await store.conditionSynthesis(for: facts)
        let originalOverview = await store.storyOverview(for: facts)
        XCTAssertNotNil(originalMapping); XCTAssertNotNil(originalOverview)
        let zip = try await store.exportData(password: password, includeOriginals: false, appVersion: "test")
        let destination = try SessionStore(storageDirectory: root.appendingPathComponent("dest"))
        let prepared = try await destination.prepareDataImport(from: zip, password: password)
        try await destination.replaceWithImportedData(prepared)
        let after = try await destination.healthSnapshot()
        let newFacts = HealthMemoryProjection.facts(in: after)
        let mapped = await destination.conditionSynthesis(for: newFacts)
        let narrative = await destination.storyOverview(for: newFacts)
        XCTAssertEqual(mapped?.groups.first?.name, "Knee pain")
        XCTAssertEqual(narrative?.text, overview.text)
        XCTAssertEqual(after.preferences.first?.reviewedRevision, "reviewed-test-version")
    }
}
