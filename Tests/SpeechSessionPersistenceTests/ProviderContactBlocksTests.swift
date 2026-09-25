import XCTest
@testable import SpeechSessionPersistence

final class ProviderContactBlocksTests: XCTestCase {
    private let source = """
    CORPORATE HEAD OFFICE
    Phone: 403 555 0100
    DR ALEX MORGAN
    Example Eye Centre
    100 - 123 Main St SW
    Calgary, AB T2H 0C8
    Phone: (403) 555-0111
    FAX: (403) 555-0112
    PATIENT, EXAMPLE
    M 44 yrs
    Ph: (416) 555-0199
    Exam Date: March 15, 2024
    CHEST X-RAY - PRELIMINARY REPORT
    Findings: Normal chest radiographs.
    Reported: 15 Mar 2024 10:06 Taylor Example MD FRCPC, phone # (403) 555-0122
    Electronically Signed: 15 Mar 2024 10:06 Taylor Example MD FRCPC, phone # (403) 555-0122
    """

    func testHeadingsAndSignaturesAreDetectedWithoutPatientOrCorporateContactContamination() {
        let blocks = ProviderContactBlocks.candidates(in: source)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].name, "DR ALEX MORGAN")
        XCTAssertTrue(blocks[0].source.contains("555-0111"))
        XCTAssertFalse(blocks[0].source.contains("555-0199"))
        XCTAssertFalse(blocks[0].source.contains("555 0100"))
        XCTAssertFalse(blocks[0].source.contains("Findings"))
        XCTAssertEqual(blocks[1].name, "Taylor Example")
        XCTAssertTrue(blocks[1].source.contains("Reported:"))
        XCTAssertFalse(blocks[1].source.contains("Example Eye Centre"))
    }

    func testMissingContactGetsSourceOnlyDraftUntilIndependentlyChecked() throws {
        let block = try XCTUnwrap(ProviderContactBlocks.candidates(in: source).first)
        let session = Session(date: Date(), transcript: source)
        let draft = ProviderContactBlocks.draft(for: block, session: session)
        XCTAssertFalse(SummaryVerification.isVisible(draft, source: source))
        let check = SummaryCheck(id: draft.id, supported: true, reason: "Named contact", citations: [.init(field: "title", excerpt: block.name)])
        var accepted = SummaryVerification.assess(draft, check: check, source: block.source)
        accepted.evidence?.assessment?.sourceHash = SummaryVerification.hash(source)
        XCTAssertTrue(SummaryVerification.isVisible(accepted, source: source))
        XCTAssertNil(accepted.evidence?.practitioner)
        XCTAssertNil(accepted.evidence?.eventDate)
    }

    func testWrongPhoneCitationCannotPassBoundedContactCheck() throws {
        let block = try XCTUnwrap(ProviderContactBlocks.candidates(in: source).first)
        var draft = ProviderContactBlocks.draft(for: block, session: Session(date: Date(), transcript: source))
        draft.fields.append(.init(label: "Phone", value: "(416) 555-0199"))
        let check = SummaryCheck(id: draft.id, supported: true, reason: "Supported", citations: [
            .init(field: "title", excerpt: block.name), .init(field: "field:Phone", excerpt: "(416) 555-0199")])
        let assessed = SummaryVerification.assess(draft, check: check, source: block.source)
        XCTAssertEqual(assessed.evidence?.assessment?.admission, .sourceOnly)
    }

    func testRepeatedBlocksAreIdempotentAndAdjacentDoctorsRemainSeparate() {
        let block = "Dr. Alex Morgan\nExample Clinic\nPhone: 403 555 0111\nPatient: Example"
        XCTAssertEqual(ProviderContactBlocks.candidates(in: block + "\n" + block).count, 1)
        let separate = ProviderContactBlocks.candidates(in: "Dr. Alex Morgan\nDr. Taylor Example\nPhone: 403 555 0122\nPatient: Example")
        XCTAssertEqual(separate.count, 2)
        XCTAssertFalse(separate[0].source.contains("555"))
        XCTAssertEqual(ProviderContactBlocks.nameKey("Dr. Alex Morgan"), ProviderContactBlocks.nameKey("DR ALEX MORGAN"))
    }
}
