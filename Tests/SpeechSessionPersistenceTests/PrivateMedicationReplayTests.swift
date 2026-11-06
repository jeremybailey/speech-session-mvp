import XCTest
@testable import SpeechSessionPersistence
final class PrivateMedicationReplayTests:XCTestCase {
    func testSavedDeviceMedicationVisibility() throws {
        guard let path=ProcessInfo.processInfo.environment["CC_PRIVATE_B_REPLAY"] else {throw XCTSkip("Private replay path not supplied")}
        let url=URL(fileURLWithPath:path),before=try Data(contentsOf:url)
        let saved=try XCTUnwrap(JSONSerialization.jsonObject(with:before) as? [String:Any])
        let raw=try XCTUnwrap(saved["output"] as? String)
        let decoded=try WholeHistoryResponseContract.decode(raw,locators:saved["locators"] as? [String:[String:Any]],originals:saved["records"] as? [[String:Any]],version:saved["contractVersion"] as? String)
        let medications=decoded.facts.filter {$0.category=="medications"}
        let visible=medications.filter {HealthStoryEligibility.usableMedicationName($0.medication?["name"])}
        XCTAssertEqual(medications.count,49)
        XCTAssertEqual(visible.count,28)
        XCTAssertEqual(before,try Data(contentsOf:url))
        print("PRIVATE REPLAY: 49 source medication rows retained; 28 named rows eligible; 21 unusable rows withheld. No originals changed.")
    }
}
