import XCTest
@testable import SpeechSessionPersistence

final class SessionTitleTests: XCTestCase {
    private func entry(_ category: SummaryEntryCategory, _ title: String) -> SummaryEntry {
        var value = SummaryEntry(category: category, title: title, details: "")
        value.origin = .userAdded
        return value
    }
    func testUntitledAndPlaceholderRecordsUseAcceptedConcern() {
        for title: String? in [nil, "Health record", "Audio record", "Appointment"] {
            var session = Session(transcript: "", title: title)
            session.summaryEntries = [entry(.medications, "Example drops"), entry(.symptoms, "Back discomfort")]
            XCTAssertEqual(session.displayTitle, "Back discomfort")
        }
    }
    func testPreservesMeaningfulTitleAndIgnoresDeletedDetails() {
        var session = Session(transcript: "", title: "My appointment with Jamie")
        session.summaryEntries = [entry(.symptoms, "Fatigue")]
        XCTAssertEqual(session.displayTitle, "My appointment with Jamie")
        session.title = nil
        session.summaryEntries?[0].isDeleted = true
        XCTAssertEqual(session.displayTitle, "Health record")
    }
    func testLabRecordUsesLabContextAndChiefComplaintTakesPriority() {
        var session = Session(transcript: "")
        session.summaryEntries = [entry(.testsAndLabs, "Ferritin"), entry(.testsAndLabs, "Vitamin B12")]
        XCTAssertEqual(session.displayTitle, "Lab results: Ferritin and more")
        session.summaryEntries?.append(entry(.chiefComplaint, "Eye discomfort"))
        XCTAssertEqual(session.displayTitle, "Eye discomfort")
    }
}
