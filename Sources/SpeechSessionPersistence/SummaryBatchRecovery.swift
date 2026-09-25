import Foundation

/// Transport/schema recovery is separate from the single clinical correction cycle.
/// A failed batch contributes no decisions or corrections. Only complete responses are retained.
public enum SummaryBatchRecovery {
    public static func run<Item, Output>(items: [Item], attempt: ([Item]) async throws -> Output) async throws -> [Output] {
        try Task.checkCancellation()
        do {
            let result = try await attempt(items)
            try Task.checkCancellation()
            return [result]
        } catch {
            try Task.checkCancellation()
            guard let failure = error as? SummaryResponseError, recoverable(failure) else { throw error }
            if items.count > 1 {
                let middle = items.count / 2
                let left = try await run(items: Array(items[..<middle]), attempt: attempt)
                let right = try await run(items: Array(items[middle...]), attempt: attempt)
                return left + right
            }
            // One retry at the smallest size, including an empty omission-check batch.
            do {
                let result = try await attempt(items)
                try Task.checkCancellation()
                return [result]
            } catch {
                try Task.checkCancellation()
                if let final = error as? SummaryResponseError, recoverable(final) {
                    throw SummaryBatchRetryFailure(reason: final)
                }
                throw error
            }
        }
    }

    private static func recoverable(_ error: SummaryResponseError) -> Bool {
        switch error {
        case .invalidFormat, .missingDecisions, .duplicateDecisions, .wrongDecisions, .responseTooLong, .responseStopped: return true
        default: return false
        }
    }
}

public struct SummaryBatchRetryFailure: LocalizedError {
    public let reason: SummaryResponseError
    public var errorDescription: String? {
        (reason.errorDescription ?? "Checking could not finish.") + " Automatic retries with individual details also failed."
    }
    public var recoverySuggestion: String? {
        "Try again later. If it still fails, contact support with this message. You do not need to re-upload or change your original record."
    }
}
