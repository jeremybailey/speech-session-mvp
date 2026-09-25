import Foundation

public enum OverviewFailure: LocalizedError {
    case inputTooLarge, invalidFormat, invalidReferences, unsupported, invalidCheckFormat, refused
    case rejectedAfterCorrection(firstReason: String, finalReason: String)

    /// Model feedback is diagnostic data, not a clinical finding or an instruction.
    public var checkerExplanation: String? {
        guard case let .rejectedAfterCorrection(firstReason, finalReason) = self else { return nil }
        let first = firstReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = finalReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = final.isEmpty ? "The checker did not explain its rejection." : final
        if first.isEmpty || first == final { return "After the rewrite: \(explanation)" }
        return "First check: \(first)\n\nAfter the rewrite: \(explanation)"
    }
    public var errorDescription: String? {
        switch self {
        case .inputTooLarge: return "Your history is larger than this overview request can process. Retrying the same request will not shorten it. Your health details remain available."
        case .invalidFormat: return "The overview writer returned an incomplete or incorrectly formatted story. Tap Create overview to retry; your health details are saved."
        case .invalidCheckFormat: return "The story was written, but its accuracy check returned an incomplete or incorrectly formatted answer. Tap Create overview to retry; your health details are saved."
        case .refused: return "The overview service declined this request. Your health details are saved. If creating the overview fails again, contact support with this message."
        case .invalidReferences: return "The overview did not correctly link its sentences to your health details. Try creating it again; your saved details are unchanged."
        case .unsupported: return "The overview could not be confirmed against your saved health details, even after an automatic rewrite and second check. Your health details are available below. You can try Create overview again."
        case .rejectedAfterCorrection: return "The automatic checker rejected the overview after a rewrite. Your health details are saved. Open ‘Why it stopped’ below for the specific explanation; retrying may give the same result."
        }
    }
}
