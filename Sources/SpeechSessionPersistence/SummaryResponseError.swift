import Foundation

/// Technical processing failures, separate from decisions about clinical support.
public enum SummaryResponseError: Error, LocalizedError, Equatable {
    case invalidFormat, missingDecisions, duplicateDecisions, wrongDecisions
    case responseTooLong, responseStopped, signInRequired, busy, quotaExceeded, serviceUnavailable, network, unknown

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "The summary service returned a response the app could not read."
        case .missingDecisions: return "The checker did not return a decision for every detail."
        case .duplicateDecisions: return "The checker returned more than one decision for the same detail."
        case .wrongDecisions: return "The checker returned decisions that did not match the details being checked."
        case .responseTooLong: return "The summary service reached its response limit before finishing."
        case .responseStopped: return "The summary service stopped before completing its response."
        case .signInRequired: return "The summary service could not authorize this request."
        case .busy: return "The summary service is busy. Please wait a minute before trying again. Your saved details are unchanged."
        case .quotaExceeded: return "The summary service has reached its usage allowance. Please contact support; retrying will not resolve this. Your saved details are unchanged."
        case .serviceUnavailable: return "The summary service is unavailable right now."
        case .network: return "The app could not finish connecting to the summary service."
        case .unknown: return "The app could not finish processing this record."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .signInRequired: return "Open Settings and check your sign-in or API key, then retry."
        case .network: return "Check your internet connection, then retry."
        case .quotaExceeded: return "Contact support to restore the summary service allowance."
        case .busy, .serviceUnavailable: return "Wait a few minutes, then retry."
        default: return "Retry the unfinished work. If this happens again, keep the original record and contact support with this message."
        }
    }

    /// AIProcessing errors carry local, sanitized messages in NSError.userInfo.
    /// NSError does not conform to LocalizedError; a protocol cast loses them.
    public static func presentation(for error: Error) -> (message: String, recovery: String) {
        let value = error as NSError
        if value.domain == "AIProcessing" {
            let recovery: String
            switch value.code {
            case 402:
                recovery = "Check AI usage in Settings. Spending and pending requests both count toward the cap. Do not repeatedly retry; contact support if processing remains blocked."
            case 401, 403:
                recovery = "Open Settings and sign in again before continuing."
            default:
                recovery = "Check AI usage in Settings and contact support with this message before retrying."
            }
            return (value.localizedDescription, recovery)
        }
        let localized = error as? LocalizedError
        return (localized?.errorDescription ?? Self.unknown.errorDescription!,
                localized?.recoverySuggestion ?? Self.unknown.recoverySuggestion!)
    }

    /// Each required UUID property owns one decision; never associate results by array position.
    public static func decodeKeyedChecks(_ value: Any?, expectedIDs: [UUID]) throws -> [SummaryCheck] {
        guard let rows = value as? [String: Any] else { throw Self.invalidFormat }
        let expected = Set(expectedIDs.map(\.uuidString))
        guard Set(rows.keys).isSubset(of: expected) else { throw Self.wrongDecisions }
        guard Set(rows.keys) == expected else { throw Self.missingDecisions }
        return try expectedIDs.flatMap { id in
            try decodeChecks([rows[id.uuidString]!], expectedIDs: [id])
        }
    }

    public static func decodeChecks(_ value: Any?, expectedIDs: [UUID]) throws -> [SummaryCheck] {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let checks = try? JSONDecoder().decode([SummaryCheck].self, from: data) else { throw Self.invalidFormat }
        let actual = Set(checks.map(\.id)), expected = Set(expectedIDs)
        guard checks.count == actual.count else { throw Self.duplicateDecisions }
        guard actual.isSubset(of: expected) else { throw Self.wrongDecisions }
        guard actual == expected else { throw Self.missingDecisions }
        return checks
    }

    public static func validateHTTPStatus(_ status: Int) throws {
        switch status {
        case 200...299: return
        case 401, 403: throw Self.signInRequired
        case 429: throw Self.busy
        default: throw Self.serviceUnavailable
        }
    }

    public static func validateFinishReason(_ reason: String?) throws {
        guard reason == "stop" else { throw reason == "length" ? Self.responseTooLong : Self.responseStopped }
    }
}
