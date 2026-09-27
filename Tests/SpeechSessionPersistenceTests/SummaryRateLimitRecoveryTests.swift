import XCTest
@testable import SpeechSessionPersistence

final class SummaryRateLimitRecoveryTests: XCTestCase {
    private actor ConcurrencyProbe {
        var active = 0
        var maximum = 0
        func enter() { active += 1; maximum = max(maximum, active) }
        func leave() { active -= 1 }
    }
    private func coordinator() -> SummaryRequestCoordinator {
        SummaryRequestCoordinator(maxConcurrent: 2, usesPersistedCooldown: false)
    }
    func testWaitsForRetryAfterThenReturnsSuccessfulOverview() async throws {
        var calls = 0
        var delays: [UInt64] = []
        let result = try await SummaryRateLimitRecovery.run(coordinator: coordinator(), sleep: { delays.append($0) }) {
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
            _ = try await SummaryRateLimitRecovery.run(coordinator: coordinator(), sleep: { delays.append($0) }) {
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
                _ = try await SummaryRateLimitRecovery.run(coordinator: coordinator(), sleep: { _ in XCTFail("No retry") }) {
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
            _ = try await SummaryRateLimitRecovery.run(coordinator: coordinator(), sleep: { _ in throw CancellationError() }) {
                calls += 1
                return ("", 429, nil, Data())
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }
    func testConnectionLossRetriesTwiceAndThenStops() async {
        var calls = 0
        var delays: [UInt64] = []
        do {
            _ = try await SummaryRateLimitRecovery.run(coordinator: coordinator(), sleep: { delays.append($0) }) {
                calls += 1
                throw URLError(.networkConnectionLost)
            } as String
            XCTFail("Expected network failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(delays, [2_000_000_000, 4_000_000_000])
    }
    func testRateLimitResetDurationHeaderIsHonored() {
        XCTAssertEqual(SummaryRateLimitRecovery.retryDelay("1500ms", attempt: 0), 1.5)
        XCTAssertEqual(SummaryRateLimitRecovery.retryDelay("7s", attempt: 0), 7)
    }
    func testLongCooldownDoesNotRetryEarly() async {
        do {
            _ = try await SummaryRateLimitRecovery.run(coordinator: coordinator(), sleep: { _ in XCTFail("No early retry") }) {
                ("", 429, "120", Data())
            }
            XCTFail("Expected busy")
        } catch { XCTAssertEqual(error as? SummaryResponseError, .busy) }
        XCTAssertEqual(SummaryRateLimitRecovery.retryDelay("Thu, 01 Jan 1970 00:00:30 GMT", attempt: 0, now: Date(timeIntervalSince1970: 0)), 30)
    }

    func testSharedCoordinatorLimitsConcurrentRequestsToTwo() async throws {
        let coordinator = coordinator()
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    _ = try await SummaryRateLimitRecovery.run(jobID: "job-\(index)", coordinator: coordinator) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 25_000_000)
                        await probe.leave()
                        return (index, 200, nil, Data())
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 2)
    }

    func testCooldownIsPersistedForRelaunch() async throws {
        let suite = "SummaryRateLimitRecoveryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SummaryRequestCoordinator(maxConcurrent: 2, defaults: defaults)
        await first.beginJob("job")
        try await first.registerRetry(jobID: "job", delay: 5)
        let persisted = try XCTUnwrap(defaults.object(forKey: "summaryRequestCooldownUntil") as? Date)
        XCTAssertGreaterThan(persisted, Date())
        let relaunched = SummaryRequestCoordinator(maxConcurrent: 2, defaults: defaults)
        let restored = await relaunched.currentCooldown()
        XCTAssertEqual(restored, persisted)
        let retries = await relaunched.retryCount(for: "job")
        XCTAssertEqual(retries, 1)
    }
}
