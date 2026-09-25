import XCTest
@testable import SpeechSessionPersistence

final class MedicationIdentityTests: XCTestCase {
    private func entry(_ title: String, dose: String? = nil, details: String = "") -> SummaryEntry {
        var e = SummaryEntry(category: .medications, title: title, details: details)
        e.evidence = ClinicalEvidence(); e.evidence?.dose = dose
        return e
    }
    func testRepeatedStrengthInOptionalDoseDoesNotSplitAnyMedication() {
        for name in ["Moxifloxacin", "Lotemax", "Nevanac", "Example Medication"] {
            let variants = [entry("\(name.uppercased()) 0.5 % EYE DROPS", dose: "0.5 %", details: "Filled at Pharmacy A for 7 days"),
                            entry("\(name) 0.5% Eye Drops", details: "Prescription filled at Pharmacy B"),
                            entry("\(name) .50 % eye drops", dose: "0.50%")]
            XCTAssertEqual(Set(variants.map(MedicationIdentity.key)).count, 1, name)
            let facts = variants.enumerated().map { index, e in
                HealthFact(id: "\(index)", occurrences: [e], preference: .init(id: "\(index)"), topicIDs: [])
            }
            XCTAssertEqual(MedicationHistoryPresentation.group(facts).first?.occurrences.count, 3)
        }
    }
    func testStrengthLocationAndRatioSpacing() {
        XCTAssertEqual(MedicationIdentity.key(entry("Example 5 mg tablet")), MedicationIdentity.key(entry("Example tablet", dose: "5mg")))
        XCTAssertEqual(MedicationIdentity.key(entry("Example 5 mg / 1 ml solution")), MedicationIdentity.key(entry("Example 5mg/1ml solution")))
        XCTAssertEqual(MedicationIdentity.key(entry("Example 5mg tablet", details: "Supply 100 ml at Pharmacy")), MedicationIdentity.key(entry("Example 5mg tablet")))
    }
    func testDifferentProductsAndUncertainStrengthStaySeparate() {
        for (a,b) in [("Example 5mg tablet", "Example 10mg tablet"), ("Example 5mg tablet", "Example 5mg capsule"),
                      ("Example 5mg tablet", "Example tablet"), ("Brand 5mg tablet", "Generic 5mg tablet"),
                      ("Example 5mg/ml solution", "Example 5mg/5ml solution")] {
            XCTAssertNotEqual(MedicationIdentity.key(entry(a)), MedicationIdentity.key(entry(b)))
        }
        var conflicting = entry("Example 5mg tablet")
        conflicting.fields = [.init(label: "Strength", value: "10mg")]
        XCTAssertNotEqual(MedicationIdentity.key(conflicting), MedicationIdentity.key(entry("Example 5mg tablet")))
    }
}
