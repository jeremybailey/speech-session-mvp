import XCTest
@testable import SpeechSessionPersistence

final class RecordDetailTagLabelTests: XCTestCase {
    func testTopicAcrossSpeakers() {
        for speaker in ["The clinician", "The attending nurse", "Dr. Patel", "Nicole"] {
            XCTAssertEqual(RecordDetailTagLabel.make("\(speaker) describes intermittent back pain."), "Intermittent back pain")
        }
        XCTAssertEqual(RecordDetailTagLabel.make("The clinician explains that it might resolve later."), "…")
        XCTAssertEqual(RecordDetailTagLabel.make("Dr. Patel mentioned a possible change in vitamin K timing.", factKey: "vitamin-k"), "Vitamin K")
        XCTAssertEqual(RecordDetailTagLabel.make("The clinician describes possible induction.", factKey: "follow-up"), "Possible induction")
    }

    func testCompactLabels() {
        XCTAssertEqual(RecordDetailTagLabel.make("The patient's mother is expected to arrive on Monday."), "Mother · Monday")
        XCTAssertEqual(RecordDetailTagLabel.make("FmL prescription"), "FmL prescription")
        XCTAssertEqual(RecordDetailTagLabel.make("Dr. Jamie Bhamra"), "Dr. Jamie Bhamra")
        XCTAssertEqual(RecordDetailTagLabel.make("  "), "…")
        XCTAssertEqual(RecordDetailTagLabel.make("The patient does not want to use castor oil now."), "Castor oil")
        XCTAssertEqual(RecordDetailTagLabel.make("Patient says she does not want to use castor oil now."), "Castor oil")
        XCTAssertEqual(RecordDetailTagLabel.make("The patient declined a membrane sweep today."), "Membrane sweep")
        XCTAssertEqual(RecordDetailTagLabel.make("The patient reported intermittent back pain."), "Intermittent back pain")
        XCTAssertEqual(RecordDetailTagLabel.make("The midwife discussed possible induction."), "Possible induction")
        XCTAssertEqual(RecordDetailTagLabel.make("It may or may not."), "…")
        XCTAssertEqual(RecordDetailTagLabel.make("The patient says that she may reconsider it later."), "…")
        XCTAssertEqual(RecordDetailTagLabel.make("The patient did not agree."), "…")
        XCTAssertEqual(RecordDetailTagLabel.make("The patient’s mother will be there."), "Mother")
        XCTAssertEqual(RecordDetailTagLabel.make("The appointment appears to be booked for the 19th."), "Appointment")
        XCTAssertEqual(RecordDetailTagLabel.make("The next appointment is booked."), "Follow-up visit")
        XCTAssertEqual(RecordDetailTagLabel.make("Vitamin K"), "Vitamin K")
        XCTAssertLessThanOrEqual(RecordDetailTagLabel.make("There was a change in the afternoon appointment schedule.").split(separator: " ").count, 4)
    }
}
