import Foundation

/// Bounded recovery shared by overview generation and structured summary requests.
public enum SummaryRateLimitRecovery {
    public static func run<T>(
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        request: () async throws -> (T, Int, String?, Data)
    ) async throws -> T {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (value, status, retryAfter, body) = try await request()
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
                try await sleep(UInt64(delay * 1_000_000_000))
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
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: header) { return max(1, date.timeIntervalSince(now)) }
        }
        return attempt == 0 ? 15 : 30
    }
}
