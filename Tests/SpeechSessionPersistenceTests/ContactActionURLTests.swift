import XCTest
@testable import SpeechSessionPersistence
final class ContactActionURLTests: XCTestCase {
    func testPhoneUsesDialerAndDoesNotAppendExtensionToNumber() {
        XCTAssertEqual(ContactActionURL.make(label: "Phone", value: "+1 (403) 555-0100 ext. 42")?.absoluteString, "tel:+14035550100")
        XCTAssertEqual(ContactActionURL.make(label: "Telephone", value: "403 555 0100")?.scheme, "tel")
        XCTAssertNil(ContactActionURL.make(label: "Phone", value: "unknown"))
    }
    func testAddressUsesMapsAndPreservesQuery() {
        let address = "Suite 10, 123 Main St & North Entry, Calgary"
        let url = ContactActionURL.make(label: "Address", value: address)!
        XCTAssertEqual(url.scheme, "maps")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, address)
        XCTAssertNil(ContactActionURL.make(label: "Address", value: ""))
    }
    func testOverviewLeadsWithComplaintBeforeEarlierPrescription() {
        var prescription = SummaryEntry(category: .medications, title: "Example medication")
        prescription.evidence = ClinicalEvidence(); prescription.evidence?.eventDate = "2020"
        let complaint = SummaryEntry(category: .chiefComplaint, title: "Back pain")
        let facts = [prescription,complaint].map { HealthFact(id: $0.id.uuidString, occurrences: [$0], preference: .init(id: $0.id.uuidString), topicIDs: []) }
        let text = HealthSummaryPresentation.overview(facts: facts)!
        XCTAssertTrue(text.hasPrefix("Concerns include Back pain"))
    }
}
