import XCTest
@testable import SpeechSessionPersistence

final class SummaryRegressionRecoveryTests: XCTestCase {
    func testPharmacyAndMachineAttributesNeverEnterStoryEvenIfSourceLinked() {
        for title in ["pharmacyName: Example Pharmacy", "pharmacy_name: Example", "Pharmacy Name: Example", "daysSupply: 7", "dateFilled: 2024-01-01", "unexpectedMetadata: value"] {
            let e = SummaryEntry(category: .medications, title: title)
            XCTAssertNotNil(SummaryEntityStructure.exclusion(e))
            let checked = SummaryVerification.sourceLinked(e, source: title, evidence: title)
            XCTAssertFalse(SummaryVerification.isVisible(checked, source: title))
        }
        XCTAssertNil(SummaryEntityStructure.exclusion(.init(category: .medications, title: "Example medicine 5mg")))
        XCTAssertNil(SummaryEntityStructure.exclusion(.init(category: .testsAndLabs, title: "eGFR: 90")))
    }
    func testStandaloneImmunizationReportRoutesToVaccinations() throws {
        let source = "Vaccinations\nDate Administered Vaccine\n2024-01-02 Example vaccine"
        let units = try XCTUnwrap(StructuredHealthReport.units(in: source))
        let unit = try XCTUnwrap(units.first { $0.kind == .immunization })
        let e = SummaryEntry(category: .medications, title: "Example vaccine")
        let routed = StructuredHealthReport.prepare(e, for: unit)
        XCTAssertEqual(routed.category, .vaccinations)
        XCTAssertNil(routed.evidence?.eventDate) // Routing cannot invent an administration date.
        let pharmacy = StructuredHealthReport.Unit(kind: .medication, source: "Prescription filled", heading: "Prescription fills")
        XCTAssertEqual(StructuredHealthReport.prepare(e, for: pharmacy).category, .medications)
    }
    func testOverviewFailuresHaveDistinctActionableDescriptions() {
        let failures: [OverviewFailure] = [.inputTooLarge, .invalidFormat, .invalidReferences, .unsupported]
        XCTAssertEqual(Set(failures.compactMap(\.errorDescription)).count, failures.count)
        XCTAssertTrue(OverviewFailure.inputTooLarge.errorDescription!.contains("Retrying the same request will not"))
    }
}
