import XCTest
@testable import SpeechSessionPersistence

final class SummaryBatchRecoveryTests: XCTestCase {
    func testSkippedDecisionsSplitUntilEveryDetailHasDecision() async throws {
        var attempts: [[Int]] = []
        let results = try await SummaryBatchRecovery.run(items: [1,2,3,4]) { batch -> [Int] in
            attempts.append(batch)
            if batch.count > 1 { throw SummaryResponseError.missingDecisions }
            return batch
        }
        XCTAssertEqual(results.flatMap { $0 }, [1,2,3,4])
        XCTAssertEqual(attempts.count, 7)
    }
    func testSuccessfulBatchesAreNotRepeated() async throws {
        var attempts: [[Int]] = []
        let results = try await SummaryBatchRecovery.run(items: [1,2,3,4]) { batch -> [Int] in
            attempts.append(batch)
            if batch.count > 2 || batch == [3,4] { throw SummaryResponseError.responseTooLong }
            return batch
        }
        XCTAssertEqual(results.flatMap { $0 }, [1,2,3,4])
        XCTAssertEqual(attempts.filter { $0 == [1,2] }.count, 1)
    }
    func testSingleDetailRetryIsBoundedAndDoesNotPublishPartialResult() async {
        var count = 0
        do {
            let _: [[Int]] = try await SummaryBatchRecovery.run(items: [1]) { _ -> [Int] in
                count += 1
                throw SummaryResponseError.missingDecisions
            }
            XCTFail("Must fail without a complete response")
        } catch {
            XCTAssertTrue(error is SummaryBatchRetryFailure)
            XCTAssertEqual(count, 2)
        }
    }
    func testSingleDetailCanRecoverWithoutRelaxingDecisionValidation() async throws {
        let id = UUID()
        var count = 0
        let output = try await SummaryBatchRecovery.run(items: [id]) { ids -> [SummaryCheck] in
            count += 1
            let rows: [[String: Any]] = count == 1 ? [] : [["id": id.uuidString, "supported": false, "reason": "Not supported", "citations": []]]
            return try SummaryResponseError.decodeChecks(rows, expectedIDs: ids)
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(output.flatMap { $0 }.count, 1)
        XCTAssertFalse(output[0][0].supported)
    }
    func testAuthorizationFailureDoesNotRetry() async {
        var count = 0
        do {
            let _: [Int] = try await SummaryBatchRecovery.run(items: [1,2]) { _ -> Int in
                count += 1
                throw SummaryResponseError.signInRequired
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? SummaryResponseError, .signInRequired) }
        XCTAssertEqual(count, 1)
    }
    func testCancellationStopsRecovery() async {
        var count = 0
        do {
            let _: [Int] = try await SummaryBatchRecovery.run(items: [1,2]) { _ -> Int in
                count += 1
                throw CancellationError()
            }
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(count, 1)
    }
    func testEmptyOmissionCheckRetriesOnlyOnce() async {
        var count = 0
        do {
            let _: [Int] = try await SummaryBatchRecovery.run(items: [Int]()) { _ -> Int in
                count += 1
                throw SummaryResponseError.invalidFormat
            }
            XCTFail()
        } catch { XCTAssertTrue(error is SummaryBatchRetryFailure) }
        XCTAssertEqual(count, 2)
    }
}
