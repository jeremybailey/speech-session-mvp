import XCTest
@testable import SpeechSessionPersistence

final class SummaryAutomaticUpdatePolicyTests: XCTestCase {
    func testUnchangedInputsAreClaimedOnlyOnce() {
        var policy = SummaryAutomaticUpdatePolicy()
        XCTAssertTrue(policy.claim("first"))
        XCTAssertFalse(policy.claim("first"))
        XCTAssertTrue(policy.claim("new record"))
    }
    func testFailureDoesNotLoopWhenProcessingChangesTheProjection() {
        var policy = SummaryAutomaticUpdatePolicy()
        XCTAssertTrue(policy.claim("initial"))
        policy.finished("partial result")
        XCTAssertFalse(policy.claim("partial result"))
        XCTAssertTrue(policy.claim("partial result", explicitlyRequested: true))
    }
    func testStopSurvivesRecreationAndNewInputCanProceed() {
        var policy = SummaryAutomaticUpdatePolicy()
        policy.stop("first")
        let restored = SummaryAutomaticUpdatePolicy(stoppedInput: policy.stoppedInput)
        XCTAssertFalse(restored.allows("first"))
        XCTAssertTrue(restored.allows("second"))
        XCTAssertTrue(policy.claim("first", explicitlyRequested: true))
        XCTAssertNil(policy.stoppedInput)
    }
    func testBackgroundInterruptionCanResume() {
        var policy = SummaryAutomaticUpdatePolicy()
        XCTAssertTrue(policy.claim("first"))
        policy.interrupted("first")
        XCTAssertTrue(policy.claim("first"))
    }
    func testStoppedInputIsNotResumedByInterruption() {
        var policy = SummaryAutomaticUpdatePolicy()
        XCTAssertTrue(policy.claim("first"))
        policy.stop("first")
        policy.interrupted("first")
        XCTAssertFalse(policy.claim("first"))
    }
}
