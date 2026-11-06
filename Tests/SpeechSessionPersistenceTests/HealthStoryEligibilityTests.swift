import XCTest
@testable import SpeechSessionPersistence

final class HealthStoryEligibilityTests: XCTestCase {
    func testRejectedIdentityIsAuditableButNeverPresented() throws {
        let medication = StructuredMedication.grounded(["name":"Invented", "dose":"one tablet"], in:["Take one tablet"])
        XCTAssertNil(medication["name"])
        XCTAssertEqual(medication["dose"], "one tablet")
        XCTAssertEqual(medication.rejectedValues?["name"], "Invented")
        var entry = SummaryEntry(category:.medications, title:"Original medication statement")
        var evidence = ClinicalEvidence()
        evidence.assessmentMethod = WholeHistoryPublication.version
        evidence.medication = medication
        entry.evidence = evidence
        XCTAssertFalse(HealthStoryEligibility.includes(entry))
        XCTAssertEqual(entry.title, "Original medication statement")
        entry.origin = .userEdited
        XCTAssertTrue(HealthStoryEligibility.includes(entry))
        XCTAssertEqual(try JSONDecoder().decode(StructuredMedication.self, from:JSONEncoder().encode(medication)), medication)
    }
    func testOptionalFieldsAreNotRequiredAndUnknownProductsStayHidden() {
        XCTAssertTrue(HealthStoryEligibility.usableMedicationName("Example product"))
        for name in ["", "unknown medication", "eye drops", "Medication — check original", "5"] {
            XCTAssertFalse(HealthStoryEligibility.usableMedicationName(name))
        }
    }
    func testOlderStoredMedicationStillDecodes() throws {
        let old = Data(#"{"values":{"name":"Example"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StructuredMedication.self, from:old)["name"], "Example")
    }
}
