import XCTest
@testable import SpeechSessionPersistence

final class StructuredHealthReportTests: XCTestCase {
    let report = """
    PERSONAL HEALTH REPORT
    Lab Results
    Jul 11, 2025 02:32 PM Ordered By
    EXAMPLE, ALEX
    CBC and Differential
    Status: Final
    Test Name Result
    WBC 5.1 x10**9/L
    Reference Range (Units)
    4.0-11.0 (x10**9/L)
    This report was generated using the My Personal Records tool. Your health information is private and should be handled with care. Only share your confidential health information
    with people you trust.
    Example Patient | Period Page: 5
    --- Page 6 ---
    Test Name
    RBC
    Result
    5.45 x10**12/L
    Reference Range (Units)
    4.30-6.00 (x10**12/L)
    Jul 12, 2025 10:00 AM Ordered By
    EXAMPLE, ALEX
    Ferritin
    Status: Final
    Test Name
    Ferritin
    Result
    161 ug/L
    Medications (Active)
    Medication Name Date Started Dosage Frequency Notes
    EXAMPLE DRUG 0.1% Jan 9, 2026 12:00 AM
    Medications (Discontinued)
    Medication Name Date Started Date Discontinued Dosage Frequency
    EXAMPLE DRUG 0.1% Oct 18, 2025 12:00 AM Nov 10, 2025 12:00 AM
    Medications (Fills)
    Medication Name Pharmacy Name Days Supply Date Filled
    EXAMPLE DRUG 0.1% Example Pharmacy 7 Jan 9, 2026 12:00 AM
    --- Page 12 ---
    EXAMPLE DRUG 0.1% Example Pharmacy 30 Nov 10, 2025 12:00 AM
    """
    func testLabUnitsRetainOrderContextAcrossPageBreaksAndExcludeFooters() throws {
        let units = try XCTUnwrap(StructuredHealthReport.units(in: report))
        let labs = units.filter { $0.kind == .lab }
        XCTAssertEqual(labs.count, 3)
        XCTAssertTrue(labs[1].source.contains("Jul 11, 2025"))
        XCTAssertTrue(labs[1].source.contains("EXAMPLE, ALEX"))
        XCTAssertTrue(labs[1].source.contains("5.45 x10**12/L"))
        XCTAssertFalse(labs[1].source.contains("Jul 12"))
        XCTAssertTrue(labs[2].source.contains("Jul 12"))
        XCTAssertFalse(units.contains { $0.source.contains("health information is private") })
    }
    func testMedicationRowsKeepDistinctEventTypesWithoutInventedDose() throws {
        let meds = try XCTUnwrap(StructuredHealthReport.units(in: report)).filter { $0.kind == .medication }
        XCTAssertEqual(meds.count, 4)
        XCTAssertEqual(meds.map(\.heading), ["Medications (Active)", "Medications (Discontinued)", "Medications (Fills)", "Medications (Fills)"])
        XCTAssertTrue(meds[3].source.contains("Days Supply"))
        XCTAssertTrue(meds[3].source.contains("30 Nov 10"))
        XCTAssertFalse(meds[3].source.contains("7 Jan 9"))
    }
    func testOrderingLabelRecognizesClinicianWithoutDrOrMDCredentials() {
        let entries = StructuredHealthReport.orderingContacts(in: report, session: Session(date: Date(), transcript: report))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "EXAMPLE, ALEX")
        XCTAssertFalse(SummaryVerification.isVisible(entries[0], source: report))
        XCTAssertTrue(entries[0].sourceExcerpt!.contains("Ordered By"))
    }
    func testProvinceAndPortalNamesAreNotRequiredAndUnknownFormatsFallBack() throws {
        let variant = report.replacingOccurrences(of: "PERSONAL HEALTH REPORT", with: "Northern Regional Patient Download").replacingOccurrences(of: "Lab Results", with: "Laboratory Results").replacingOccurrences(of: "Medications (Active)", with: "Active medications")
        let units = try XCTUnwrap(StructuredHealthReport.units(in: variant))
        XCTAssertTrue(units.contains { $0.source.contains("Laboratory Results") })
        XCTAssertTrue(units.contains { $0.source.contains("Active medications") })
        XCTAssertNil(StructuredHealthReport.units(in: "A visit note with a different layout"))
    }
    func testPresentationMetadataDoesNotBecomeRequiredClinicalEvidence() throws {
        let unit = try XCTUnwrap(StructuredHealthReport.units(in: report)?.first)
        var entry = SummaryEntry(category: .testsAndLabs, title: "WBC", fields: [.init(label: "Result", value: "5.1 x10**9/L"), .init(label: "Body area", value: "Other")])
        entry.evidence = ClinicalEvidence()
        entry.evidence?.bodySystem = "Other"; entry.evidence?.topicNames = ["Blood"]
        entry.evidence?.statusExplicit = true
        let prepared = StructuredHealthReport.prepare(entry, for: unit)
        let required = SummaryVerification.requiredFields(prepared)
        XCTAssertTrue(required.contains("field:Result"))
        XCTAssertFalse(required.contains("bodySystem"))
        XCTAssertFalse(required.contains("topicNames"))
        XCTAssertFalse(required.contains("clinicalStatus"))
        XCTAssertFalse(SummaryVerification.isVisible(prepared, source: report))
    }
}

extension StructuredHealthReportTests {
    func testBatchingPreservesEveryUnitAndDoesNotMixMedicationStates() throws {
        let units = try XCTUnwrap(StructuredHealthReport.units(in: report))
        let batches = StructuredHealthReport.batches(units, limit: 2500)
        for unit in units { XCTAssertTrue(batches.contains { $0.source.contains(unit.source) }) }
        XCTAssertFalse(batches.contains { $0.source.contains("Medications (Active)") && $0.source.contains("Medications (Discontinued)") })
    }
}
