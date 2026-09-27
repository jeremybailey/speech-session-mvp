import Foundation

/// Coordinates all cloud summary traffic from this app process. The persisted
/// cooldown prevents relaunches from immediately repeating a throttled request.
public actor SummaryRequestCoordinator {
    public static let shared = SummaryRequestCoordinator(maxConcurrent: 2, defaults: .standard)
    private let maxConcurrent: Int
    private let defaults: UserDefaults?
    private let usesPersistedCooldown: Bool
    private let cooldownKey = "summaryRequestCooldownUntil"
    private let retriesKey = "summaryRequestRetriesByJob"
    private var active = 0
    private var cooldownUntil: Date?
    private var retriesByJob: [String: Int] = [:]

    public init(maxConcurrent: Int = 2, defaults: UserDefaults? = nil, usesPersistedCooldown: Bool = true) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.defaults = defaults
        self.usesPersistedCooldown = usesPersistedCooldown
        if usesPersistedCooldown {
            if let value = defaults?.object(forKey: cooldownKey) as? Date { cooldownUntil = value }
            if let values = defaults?.dictionary(forKey: retriesKey) as? [String: Int] { retriesByJob = values }
        }
    }

    public func beginJob(_ id: String) { _ = id }
    public func finishJob(_ id: String) { retriesByJob[id] = nil; persistRetries() }

    public func acquire() async throws {
        while true {
            try Task.checkCancellation()
            if usesPersistedCooldown, let until = cooldownUntil, until > Date() {
                let nanos = UInt64(min(until.timeIntervalSinceNow, 60) * 1_000_000_000)
                try await Task.sleep(nanoseconds: max(nanos, 50_000_000))
                continue
            }
            if active < maxConcurrent { active += 1; return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    public func release() { active = max(0, active - 1) }

    public func registerRetry(jobID: String, delay: Double) throws {
        let count = (retriesByJob[jobID] ?? 0) + 1
        guard count <= 6 else { throw SummaryResponseError.busy }
        retriesByJob[jobID] = count
        persistRetries()
        let until = Date().addingTimeInterval(max(1, delay) + Double.random(in: 0...0.75))
        if usesPersistedCooldown && (cooldownUntil == nil || until > cooldownUntil!) {
            cooldownUntil = until
            defaults?.set(until, forKey: cooldownKey)
        }
    }
    public func requiresLocalSleep() -> Bool { !usesPersistedCooldown }
    func currentCooldown() -> Date? { cooldownUntil }
    func retryCount(for jobID: String) -> Int { retriesByJob[jobID] ?? 0 }
    private func persistRetries() {
        guard usesPersistedCooldown else { return }
        defaults?.set(retriesByJob, forKey: retriesKey)
    }
}

/// Bounded recovery shared by overview generation and structured summary requests.
public enum SummaryRateLimitRecovery {
    public static func run<T>(
        jobID: String = "standalone",
        coordinator: SummaryRequestCoordinator = .shared,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        request: () async throws -> (T, Int, String?, Data)
    ) async throws -> T {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            try await coordinator.acquire()
            let response: (T, Int, String?, Data)
            do {
                response = try await request()
                await coordinator.release()
            } catch {
                await coordinator.release()
                try Task.checkCancellation()
                if attempt < 2, isRetryableTransport(error) {
                    let delay = Double((attempt + 1) * 2)
                    try await coordinator.registerRetry(jobID: jobID, delay: delay)
                    if await coordinator.requiresLocalSleep() {
                        try await sleep(UInt64(delay * 1_000_000_000))
                    }
                    continue
                }
                throw error
            }
            let (value, status, retryAfter, body) = response
            try Task.checkCancellation()
            if status == 429 {
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                let error = json?["error"] as? [String: Any]
                let codes = [error?["code"] as? String, error?["type"] as? String].compactMap { $0 }
                if codes.contains("insufficient_quota") || codes.contains("billing_hard_limit_reached") {
                    throw SummaryResponseError.quotaExceeded
                }
                let delay = retryDelay(retryAfter, attempt: attempt)
                guard attempt < 2, delay <= 60 else { throw SummaryResponseError.busy }
                try await coordinator.registerRetry(jobID: jobID, delay: delay)
                // The coordinator owns the shared cooldown; the injected sleep keeps
                // unit tests deterministic without creating a second production wait.
                if await coordinator.requiresLocalSleep() {
                    try await sleep(UInt64(delay * 1_000_000_000))
                }
                continue
            }
            try SummaryResponseError.validateHTTPStatus(status)
            return value
        }
        throw SummaryResponseError.busy
    }

    static func retryDelay(_ header: String?, attempt: Int, now: Date = Date()) -> Double {
        if let header {
            if let seconds = Double(header), seconds.isFinite { return max(1, seconds) }
            let compact = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if compact.hasSuffix("ms"), let milliseconds = Double(compact.dropLast(2)) {
                return max(1, milliseconds / 1_000)
            }
            if compact.hasSuffix("s"), let seconds = Double(compact.dropLast()) {
                return max(1, seconds)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: header) { return max(1, date.timeIntervalSince(now)) }
        }
        return attempt == 0 ? 15 : 30
    }

    private static func isRetryableTransport(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [URLError.networkConnectionLost, .timedOut, .notConnectedToInternet,
                .cannotConnectToHost, .dnsLookupFailed].map(\.rawValue).contains(value.code)
    }
}
