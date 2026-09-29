import XCTest
@testable import SpeechSessionPersistence

final class SummaryJobResumePolicyTests: XCTestCase {
    func testSuccessfulJobClearsPendingStateEvenInBackground() {
        XCTAssertFalse(SummaryJobResumePolicy.shouldRetainPendingJob(
            completedSuccessfully: true,
            taskWasCancelled: false,
            wasBackgrounded: true,
            appIsActive: false
        ))
    }

    func testInterruptedOrBackgroundFailedJobRemainsPending() {
        XCTAssertTrue(SummaryJobResumePolicy.shouldRetainPendingJob(
            completedSuccessfully: false,
            taskWasCancelled: true,
            wasBackgrounded: false,
            appIsActive: true
        ))
        XCTAssertTrue(SummaryJobResumePolicy.shouldRetainPendingJob(
            completedSuccessfully: false,
            taskWasCancelled: false,
            wasBackgrounded: true,
            appIsActive: true
        ))
        XCTAssertTrue(SummaryJobResumePolicy.shouldRetainPendingJob(
            completedSuccessfully: false,
            taskWasCancelled: false,
            wasBackgrounded: false,
            appIsActive: false
        ))
    }

    func testForegroundFailureDoesNotAutomaticallyLoop() {
        XCTAssertFalse(SummaryJobResumePolicy.shouldRetainPendingJob(
            completedSuccessfully: false,
            taskWasCancelled: false,
            wasBackgrounded: false,
            appIsActive: true
        ))
    }

    func testResumeWaitsForCleanupAndForeground() {
        XCTAssertFalse(SummaryJobResumePolicy.canResume(
            hasPendingJob: true, hasLoaded: true, isLaunching: true,
            isProcessing: false, appIsActive: true, processingIsAllowed: true
        ))
        XCTAssertFalse(SummaryJobResumePolicy.canResume(
            hasPendingJob: true, hasLoaded: true, isLaunching: false,
            isProcessing: false, appIsActive: false, processingIsAllowed: true
        ))
        XCTAssertTrue(SummaryJobResumePolicy.canResume(
            hasPendingJob: true, hasLoaded: true, isLaunching: false,
            isProcessing: false, appIsActive: true, processingIsAllowed: true
        ))
    }

    func testRecordJobCannotFinishWhileDurableRecordsRemainPending() {
        XCTAssertFalse(SummaryJobResumePolicy.recordJobCompleted(
            hasProcessingIssue: false,
            hasError: false,
            unfinishedRecordCount: 1,
            conditionOrganizationFailed: false
        ))
        XCTAssertTrue(SummaryJobResumePolicy.recordJobCompleted(
            hasProcessingIssue: false,
            hasError: false,
            unfinishedRecordCount: 0,
            conditionOrganizationFailed: false
        ))
    }

    func testCombinedRecordJobRequiresConditionOrganizationToFinish() {
        XCTAssertFalse(SummaryJobResumePolicy.recordJobCompleted(
            hasProcessingIssue: false,
            hasError: false,
            unfinishedRecordCount: 0,
            conditionOrganizationFailed: true
        ))
    }
}
