import XCTest
@testable import SpeechSessionPersistence

final class StructuredLabDraftTests: XCTestCase {
    private func panel(_ date: String, _ name: String, _ result: String, _ range: String, _ flag: String) -> String {
        """
        Lab Results
        \(date) Ordered By
        EXAMPLE, CLINICIAN
        Lipid Panel
        Status: Final
        Test Name
        \(name)
        Result
        \(result)
        Reference Range (Units)
        \(range)
        Abnormality
        \(flag)
        Result Comment
        Generic guidance is not a patient diagnosis or treatment recommendation.
        """
    }
    func testDatedLipidFlagsReachConditionInputWithoutManualReview() throws {
        let source = panel("Jul 10, 2025 02:30 PM", "Low Density Lipoprotein Cholesterol (Calculated)", "4.60 mmol/L", "<3.50 (mmol/L)", "Above normal range") + "\n" +
            panel("Dec 17, 2025 10:00 AM", "Low Density Lipoprotein Cholesterol (Calculated)", "3.70 mmol/L", "<3.50 (mmol/L)", "Above normal range") + "\n" +
            panel("Dec 17, 2025 10:00 AM", "HDL Cholesterol", "1.20 mmol/L", ">=1.00 (mmol/L)", "-")
        let session = Session(transcript: source)
        let units = try XCTUnwrap(StructuredHealthReport.units(in: source))
        let batches = StructuredHealthReport.batches(units, limit: 2500)
        let drafts = try batches.flatMap { try XCTUnwrap(StructuredHealthReport.labDrafts(in: $0, session: session)) }
        XCTAssertEqual(drafts.count, 3)
        XCTAssertEqual(drafts.filter { $0.fields.contains { $0.label == "Abnormality" } }.count, 2)
        XCTAssertEqual(drafts[0].evidence?.eventDate, "Jul 10, 2025 02:30 PM")
        XCTAssertEqual(drafts[1].evidence?.eventDate, "Dec 17, 2025 10:00 AM")
        XCTAssertFalse(drafts[2].fields.contains { $0.label == "Abnormality" })
        XCTAssertTrue(drafts.allSatisfy { $0.evidence?.assessment == nil }) // No automatic clinical approval.
        let linked = drafts.map { SummaryVerification.sourceLinked($0, source: source, evidence: $0.sourceExcerpt!) }
        let facts = HealthMemoryProjection.facts(in: .init(sessions: [Session(transcript: source, summaryEntries: linked)]))
        let input = try ConditionSynthesis.input(facts)
        XCTAssertTrue(input.contains("Above normal range"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let values = entries.flatMap { ($0["fields"] as? [[String: String]] ?? []).compactMap { $0["value"] } }
        XCTAssertTrue(values.contains("4.60 mmol/L"))
        XCTAssertTrue(values.contains("3.70 mmol/L"))
        XCTAssertTrue(facts.allSatisfy { !$0.isReviewed })
        XCTAssertTrue(drafts.allSatisfy { $0.details.isEmpty }) // No recommendation copied from boilerplate.
    }
    func testFastingRowWithoutReferenceRangeDoesNotDiscardAdjacentLDL() throws {
        let source = panel("Dec 17, 2025 10:00 AM", "LDL Cholesterol", "3.70 mmol/L", "<3.50 (mmol/L)", "Above normal range") + "\n" +
            panel("Dec 17, 2025 10:00 AM", "Hours Fasting", "15.8 hour(s)", "-", "-")
        let units = try XCTUnwrap(StructuredHealthReport.units(in: source))
        let batch = try XCTUnwrap(StructuredHealthReport.batches(units, limit: 2500).first)
        let entries = try XCTUnwrap(StructuredHealthReport.labDrafts(in: batch, session: Session(transcript: source)))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].fields.first { $0.label == "Abnormality" }?.value, "Above normal range")
        XCTAssertFalse(entries[1].fields.contains { $0.label == "Reference range" })
    }
    func testAmbiguousOrIncompleteRowsFallBackRatherThanGuess() throws {
        let source = panel("Dec 17, 2025 10:00 AM", "LDL", "3.70 mmol/L", "<3.50 (mmol/L)", "Above normal range")
        for text in [source.replacingOccurrences(of: "Result\n3.70", with: "3.70"),
                     source.replacingOccurrences(of: "Above normal range", with: "Unclear flag"),
                     source.replacingOccurrences(of: "Reference Range (Units)\n<3.50 (mmol/L)", with: "Reference Range (Units)\nAbnormality\n<3.50 (mmol/L)")] {
            let unit = try XCTUnwrap(StructuredHealthReport.units(in: text)?.first)
            XCTAssertNil(StructuredHealthReport.labDrafts(in: unit, session: Session(transcript: text)))
        }
    }
}
