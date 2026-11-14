import XCTest
@testable import SpeechSessionPersistence

final class RecordFolderTests: XCTestCase {
    func testAutomaticIndexCombinesExplicitComponentsAndLipidMeasurements() {
        let visit = Session(transcript: "Synthetic visit")
        let other = Session(transcript: "Another visit")
        func condition(_ name: String, _ id: UUID, system: String) -> ConditionSummary {
            let entry = SummaryEntry(category:.findings,title:name,sourceSessionID:id)
            let fact = HealthFact(id:name,occurrences:[entry],preference:.init(id:name),topicIDs:[])
            return ConditionSummary(id:name,name:name,bodySystem:system,facts:[fact])
        }
        let names = ["Corneal injury and dry eye", "dry eye", "cornea eye injury", "chronic eye care condition", "impaired vision"]
        let eyes = names.map { condition($0, $0 == "dry eye" ? other.id : visit.id, system:"eye") }
        let singular = condition("Dry eye", visit.id, system: "eye")
        let plural = condition("Dry eyes", other.id, system: "eye")
        let index = RecordFolderLibrary(snapshot: .init(sessions: [visit, other]), conditions: [singular, plural])
        XCTAssertEqual(index.folders.count, 1)
        XCTAssertEqual(index.folders.first.flatMap { index.recordIDs[$0.id] }, [visit.id, other.id])
        let lipids = ["Elevated LDL cholesterol","Elevated total cholesterol"].map { condition($0,visit.id,system:"cardiovascular") }
        let library = RecordFolderLibrary(snapshot:.init(sessions:[visit,other]),conditions: eyes + lipids)
        XCTAssertEqual(library.folders.count,3)
        let compound = library.folders.first { $0.conditionID == names[0] }
        XCTAssertEqual(compound.flatMap { library.recordIDs[$0.id] }, [visit.id,other.id])
        XCTAssertTrue(library.folders.contains { $0.name == "Elevated cholesterol" })
    }

    func testStaleSourceRequiresOneExactOwner() {
        let entry = SummaryEntry(category: .symptoms, title: "Migraine", sourceSessionID: UUID(), origin: .userAdded)
        var record = Session(transcript: "Synthetic")
        record.summaryEntries = [entry]
        let fact = HealthFact(id: "m", occurrences: [entry], preference: .init(id: "m"), topicIDs: [])
        let condition = ConditionSummary(id: "m", name: "Migraine", bodySystem: "neurological", facts: [fact])
        func projection(_ records: [Session]) -> RecordFolderLibrary {
            RecordFolderLibrary(snapshot: .init(sessions: records), conditions: [condition])
        }
        XCTAssertEqual(projection([record]).recordIDs.values.first, [record.id])
        var duplicate = Session(transcript: "Synthetic copy")
        duplicate.summaryEntries = [entry]
        XCTAssertTrue(projection([record, duplicate]).folders.isEmpty)
        XCTAssertTrue(projection([]).folders.isEmpty)
    }

    func testMultiFolderFilingSurvivesRefreshDeletionAndBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("live")
        let store = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let visit = Session(transcript: "Synthetic visit")
        let second = Session(transcript: "Another synthetic visit")
        var legacy = Session(transcript: "Legacy record")
        let custom = SessionFolder(name: "Appointments")
        legacy.folderID = custom.id
        try await store.upsertFolder(custom)
        try await store.save([visit, second, legacy])

        func condition(_ name: String, _ records: [UUID], assertion: String? = nil) -> ConditionSummary {
            let entries = records.map { SummaryEntry(category: .symptoms, title: assertion ?? name,
                                                       sourceSessionID: $0, origin: .userAdded) }
            let fact = HealthFact(id: name, occurrences: entries, preference: HealthFactPreference(id: name), topicIDs: [])
            return ConditionSummary(id: name, name: name, bodySystem: "neurological", facts: [fact])
        }
        let groups = [condition("Migraine", [visit.id, second.id]), condition("Ankle pain", [visit.id]),
                      condition("TB", [visit.id], assertion: "TB was to be ruled out.")]
        func library(_ store: SessionStore) async throws -> RecordFolderLibrary {
            RecordFolderLibrary(snapshot: try await store.healthSnapshot(), conditions: groups)
        }
        var libraryView = try await library(store)
        let migraine = try XCTUnwrap(libraryView.folders.first { $0.conditionID == "Migraine" })
        var ankle = try XCTUnwrap(libraryView.folders.first { $0.conditionID == "Ankle pain" })
        XCTAssertFalse(libraryView.folders.contains { $0.conditionID == "TB" })
        XCTAssertEqual(libraryView.memberships[visit.id], [migraine.id, ankle.id])
        XCTAssertEqual(libraryView.memberships[legacy.id], [custom.id])
        try await store.setRecordFolders(recordID: visit.id, folders: [ankle])
        try await store.upsert(visit) // A processing result captured before the patient filed this record.
        ankle.name = "Ankle recovery"
        ankle.bodySystem = "movement"
        try await store.upsertFolder(ankle)
        try await store.setRecordFolderDeleted(true, folder: ankle)
        libraryView = try await library(store)
        XCTAssertEqual(libraryView.memberships[visit.id], [])
        try await store.setRecordFolderDeleted(false, folder: ankle)
        libraryView = try await library(store)
        XCTAssertEqual(libraryView.memberships[visit.id], [ankle.id])
        try await store.setRecordFolders(recordID: second.id, folders: [])
        libraryView = try await library(store)
        XCTAssertFalse(libraryView.folders.contains { $0.id == migraine.id })
        XCTAssertTrue(libraryView.selectableFolders.contains { $0.id == migraine.id })
        let empty = SessionFolder(name: "My new condition")
        try await store.upsertFolder(empty)
        libraryView = try await library(store)
        XCTAssertTrue(libraryView.folders.contains { $0.id == empty.id })
        try await store.setRecordFolderDeleted(true, folder: migraine)
        let newVisit = Session(transcript: "New visit")
        try await store.upsert(newVisit)
        let reopened = try SessionStore(storageDirectory: directory)
        let refreshed = RecordFolderLibrary(snapshot: try await reopened.healthSnapshot(),
            conditions: [condition("Ankle pain", [newVisit.id, second.id])])
        XCTAssertEqual(refreshed.memberships[newVisit.id], [ankle.id])
        XCTAssertEqual(refreshed.memberships[second.id], [])

        let password = "synthetic-fixture-password"
        let zip = try await reopened.exportData(password: password, includeOriginals: false, appVersion: "test")
        let restored = try SessionStore(storageDirectory: root.appendingPathComponent("restore"), sqliteEnabled: true)
        let prepared = try await restored.prepareDataImport(from: zip, password: password)
        try await restored.replaceWithImportedData(prepared)
        libraryView = try await library(restored)
        XCTAssertEqual(libraryView.memberships[visit.id], [ankle.id])
        XCTAssertEqual(libraryView.memberships[second.id], [])
        XCTAssertEqual(libraryView.memberships[legacy.id], [custom.id])
        XCTAssertFalse(libraryView.folders.contains { $0.id == migraine.id })
        XCTAssertEqual(libraryView.folders.first { $0.id == ankle.id }?.name, "Ankle recovery")
        XCTAssertEqual(libraryView.folders.first { $0.id == ankle.id }?.bodySystem, "movement")
    }
}
