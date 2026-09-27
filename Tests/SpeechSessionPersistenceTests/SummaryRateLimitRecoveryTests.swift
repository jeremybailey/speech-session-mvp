import XCTest
@testable import SpeechSessionPersistence

final class SummaryRateLimitRecoveryTests: XCTestCase {
    func testWaitsForRetryAfterThenReturnsSuccessfulOverview() async throws {
        var calls = 0
        var delays: [UInt64] = []
        let result = try await SummaryRateLimitRecovery.run(sleep: { delays.append($0) }) {
            calls += 1
            return ("overview", calls == 1 ? 429 : 200, "7", Data())
        }
        XCTAssertEqual(result, "overview")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(delays, [7_000_000_000])
    }
    func testPersistentLimitIsBounded() async {
        var calls = 0
        var delays: [UInt64] = []
        do {
            _ = try await SummaryRateLimitRecovery.run(sleep: { delays.append($0) }) {
                calls += 1
                return ("", 429, nil, Data())
            }
            XCTFail("Expected rate limit")
        } catch { XCTAssertEqual(error as? SummaryResponseError, .busy) }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(delays, [15_000_000_000, 30_000_000_000])
    }
    func testQuotaAndAuthorizationDoNotRetry() async {
        for status in [429, 401] {
            var calls = 0
            do {
                _ = try await SummaryRateLimitRecovery.run(sleep: { _ in XCTFail("No retry") }) {
                    calls += 1
                    return ("", status, nil, Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8))
                }
                XCTFail("Expected error")
            } catch { XCTAssertEqual(error as? SummaryResponseError, status == 429 ? .quotaExceeded : .signInRequired) }
            XCTAssertEqual(calls, 1)
        }
    }
    func testCancellationDuringCooldown() async {
        var calls = 0
        do {
            _ = try await SummaryRateLimitRecovery.run(sleep: { _ in throw CancellationError() }) {
                calls += 1
                return ("", 429, nil, Data())
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }
    func testLongCooldownDoesNotRetryEarly() async {
        do {
            _ = try await SummaryRateLimitRecovery.run(sleep: { _ in XCTFail("No early retry") }) {
                ("", 429, "120", Data())
            }
            XCTFail("Expected busy")
        } catch { XCTAssertEqual(error as? SummaryResponseError, .busy) }
        XCTAssertEqual(SummaryRateLimitRecovery.retryDelay("Thu, 01 Jan 1970 00:00:30 GMT", attempt: 0, now: Date(timeIntervalSince1970: 0)), 30)
    }
}
