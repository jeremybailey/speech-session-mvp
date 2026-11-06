import XCTest
@testable import SpeechSessionPersistence
final class WholeHistoryRecoveryPolicyTests: XCTestCase {
    func testPartialPublicationNeedsNewAttemptRatherThanReplayingCompletedResult() {
        XCTAssertTrue(WholeHistoryRecoveryPolicy.requiresNewAttempt(generationTerminal: true, generationCompleted: true, overviewTerminal: true, overviewCompleted: true, retainedRecords: 3))
        XCTAssertFalse(WholeHistoryRecoveryPolicy.requiresNewAttempt(generationTerminal: true, generationCompleted: true, overviewTerminal: true, overviewCompleted: true, retainedRecords: 0))
    }
    func testSavedValidationFailureCanBeRecheckedWithoutNewGeneration() {
        XCTAssertFalse(WholeHistoryRecoveryPolicy.requiresNewAttempt(generationTerminal:true,generationCompleted:false,overviewTerminal:false,overviewCompleted:false,retainedRecords:0,canRevalidateSavedDetails:true))
    }
    func testPendingWorkResumesAndTerminalFailuresNeedNewAttempt() {
        XCTAssertFalse(WholeHistoryRecoveryPolicy.requiresNewAttempt(generationTerminal: false, generationCompleted: false, overviewTerminal: false, overviewCompleted: false, retainedRecords: 0))
        XCTAssertTrue(WholeHistoryRecoveryPolicy.requiresNewAttempt(generationTerminal: true, generationCompleted: false, overviewTerminal: false, overviewCompleted: false, retainedRecords: 0))
        XCTAssertTrue(WholeHistoryRecoveryPolicy.requiresNewAttempt(generationTerminal: true, generationCompleted: true, overviewTerminal: true, overviewCompleted: false, retainedRecords: 0))
    }
}
