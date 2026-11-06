import XCTest
@testable import SpeechSessionPersistence
final class PrivateConditionArchiveReplayTests:XCTestCase {
    func testImportedSavedConditionOrganizationSurvivesIncrementalPresentation() async throws {
        guard let path=ProcessInfo.processInfo.environment["CC_PRIVATE_CONDITION_ARCHIVE"] else {throw XCTSkip("Private archive path not supplied")}
        let source=URL(fileURLWithPath:path),root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        for name in ["sessions.json","condition-synthesis.json","story-overview.json"] {try FileManager.default.copyItem(at:source.appendingPathComponent(name),to:root.appendingPathComponent(name))}
        let store=try SessionStore(storageDirectory:root),snapshot=try await store.healthSnapshot()
        let projected=HealthMemoryProjection.facts(in:snapshot)
        let before=ConditionSummaryProjection.groups(facts:projected,topics:snapshot.topics)
        let displayed=await store.displayedConditionFacts(for:projected)
        let after=ConditionSummaryProjection.groups(facts:displayed,topics:snapshot.topics)
        let eligible=after.filter(ConditionSummaryProjection.isNavigationEligible)
        XCTAssertFalse(eligible.contains { $0.name.lowercased() == "tiredness" })
        XCTAssertTrue(after.contains { $0.name.lowercased() == "tiredness" })
        XCTAssertEqual(eligible.count, 8)
        XCTAssertEqual(Set(projected.map(\.id)),Set(displayed.map(\.id)))
        let areas=HealthAreaProjection.groups(eligible)
        print("PRIVATE NAVIGATION REPLAY: eligibleGroups=\(eligible.count), retainedFacts=\(displayed.count)")
        print("PRIVATE CONDITION REPLAY: records=\(snapshot.sessions.count), facts=\(projected.count), rawGroups=\(before.filter{!$0.isUncategorized}.count), restoredGroups=\(after.filter{!$0.isUncategorized}.count), areas=\(areas.count)")
        XCTAssertEqual(snapshot.sessions.count,11)
        XCTAssertEqual(Set(projected.map(\.id)),Set(displayed.map(\.id)))
        XCTAssertTrue(areas.contains {$0.id == .eye})
        XCTAssertTrue(areas.contains {$0.id == .cardiovascular})
        XCTAssertTrue(areas.contains {$0.id == .movement})
    }
}
