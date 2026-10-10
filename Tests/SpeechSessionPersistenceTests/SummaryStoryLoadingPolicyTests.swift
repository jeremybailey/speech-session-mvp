import XCTest
@testable import SpeechSessionPersistence

final class SummaryStoryLoadingPolicyTests: XCTestCase {
    func testImportedOrIdleHistoryDoesNotPretendToBeLoading() {
        XCTAssertFalse(SummaryStoryLoadingPolicy.showsPlaceholder(hasLoaded: true,
            needsConditionOrganization: true, isWorking: false, hasFailure: false))
    }
    func testWorkAndCancellationTransitionOutOfPlaceholder() {
        XCTAssertTrue(SummaryStoryLoadingPolicy.showsPlaceholder(hasLoaded: true,
            needsConditionOrganization: true, isWorking: true, hasFailure: false))
        XCTAssertFalse(SummaryStoryLoadingPolicy.showsPlaceholder(hasLoaded: true,
            needsConditionOrganization: true, isWorking: false, hasFailure: false))
        XCTAssertFalse(SummaryStoryLoadingPolicy.showsPlaceholder(hasLoaded: true,
            needsConditionOrganization: false, isWorking: true, hasFailure: false))
    }
    func testFailureIsNeverMaskedByPlaceholder() {
        for loaded in [false, true] {
            XCTAssertFalse(SummaryStoryLoadingPolicy.showsPlaceholder(hasLoaded: loaded,
                needsConditionOrganization: true, isWorking: true, hasFailure: true))
        }
        XCTAssertTrue(SummaryStoryLoadingPolicy.showsPlaceholder(hasLoaded: false,
            needsConditionOrganization: false, isWorking: false, hasFailure: false))
    }
}
