import XCTest
@testable import SpeechSessionPersistence

final class ContactFieldVerificationTests: XCTestCase {
    let source = """
    --- Page 1 ---
    EXAMPLE EYE CENTRE
    Patient's Name:
    Address:
    Dr. Alex Morgan
    BSc MD FRCSC
    Eye Physician and Surgeon
    Example, Patient
    Date:
    6-2-2026
    Prescription text
    Example Eye Centre, Suite 1705
    123 Main St NW, Calgary, AB
    Phone: 403 555 0111
    """
    private func checked(_ entry: SummaryEntry, approve: Bool) -> SummaryEntry {
        let check = SummaryCheck(id: entry.id, supported: approve, reason: approve ? "Supported" : "Specialty differs from source", citations: SummaryVerification.requiredFields(entry).map { .init(field: $0, excerpt: source) })
        return SummaryVerification.assess(entry, check: check, source: source)
    }
    func testRejectedSpecialtyDoesNotDiscardSupportedNamePhoneAndClinic() throws {
        let session = Session(date: Date(), transcript: source)
        let block = try XCTUnwrap(ProviderContactBlocks.candidates(in: source).first)
        let identity = ProviderContactBlocks.draft(for: block, session: session)
        let rich = SummaryEntry(category: .practitionerContact, title: identity.title, fields: [
            .init(label: "Role or specialty", value: "Optometrist"),
            .init(label: "Phone", value: "403 555 0111"),
            .init(label: "Organization", value: "Example Eye Centre")])
        let drafts = ContactFieldVerification.drafts(identity: identity, extracted: [rich])
        let reviewed = drafts.map { checked($0, approve: !$0.fields.contains { $0.label == "Role or specialty" }) }
        let result = try XCTUnwrap(ContactFieldVerification.assemble(identityID: identity.id, reviewed: reviewed, source: source))
        XCTAssertTrue(SummaryVerification.isVisible(result, source: source))
        XCTAssertEqual(Set(result.fields.map(\.label)), ["Name", "Organization", "Phone"])
        XCTAssertEqual(result.evidence?.omittedFields, ["Role or specialty"])
        XCTAssertTrue(result.reviewReason!.contains("Role or specialty"))
    }
    func testPageContextRetainsFooterAndStopsAtNextPage() throws {
        let original = source + "\n--- Page 2 ---\nUnrelated Clinic\nPhone: 403 555 0999"
        let block = try XCTUnwrap(ProviderContactBlocks.candidates(in: original).first)
        XCTAssertFalse(block.source.contains("Prescription"))
        let context = ProviderContactBlocks.evidenceContext(for: block, in: original)
        XCTAssertTrue(context.contains("Eye Physician and Surgeon"))
        XCTAssertTrue(context.contains("403 555 0111"))
        XCTAssertFalse(context.contains("403 555 0999"))
    }
    func testRejectedIdentityCannotBePublishedThroughApprovedOptionalField() throws {
        let identity = ProviderContactBlocks.draft(for: try XCTUnwrap(ProviderContactBlocks.candidates(in: source).first), session: Session(date: Date(), transcript: source))
        let rich = SummaryEntry(category: .practitionerContact, title: identity.title, fields: [.init(label: "Phone", value: "403 555 0111")])
        let drafts = ContactFieldVerification.drafts(identity: identity, extracted: [rich])
        let result = try XCTUnwrap(ContactFieldVerification.assemble(identityID: identity.id, reviewed: drafts.map { checked($0, approve: $0.id != identity.id) }, source: source))
        XCTAssertFalse(SummaryVerification.isVisible(result, source: source))
    }
    func testConflictingVerifiedPhoneValuesAreNotChosenArbitrarily() throws {
        let identity = ProviderContactBlocks.draft(for: try XCTUnwrap(ProviderContactBlocks.candidates(in: source).first), session: Session(date: Date(), transcript: source))
        let rich = SummaryEntry(category: .practitionerContact, title: identity.title, fields: [.init(label: "Phone", value: "403 555 0111"), .init(label: "Phone", value: "403 555 0122")])
        let drafts = ContactFieldVerification.drafts(identity: identity, extracted: [rich])
        let result = try XCTUnwrap(ContactFieldVerification.assemble(identityID: identity.id, reviewed: drafts.map { checked($0, approve: true) }, source: source))
        XCTAssertTrue(SummaryVerification.isVisible(result, source: source))
        XCTAssertFalse(result.fields.contains { $0.label == "Phone" })
        XCTAssertEqual(result.evidence?.omittedFields, ["Phone"])
    }
}
