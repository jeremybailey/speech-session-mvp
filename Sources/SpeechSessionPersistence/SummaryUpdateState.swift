import Foundation

public enum SummaryUpdateRegion: String, CaseIterable, Identifiable, Sendable {
    case details, conditions, overview
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .details: return "Read records"
        case .conditions: return "Organize conditions"
        case .overview: return "Update overview"
        }
    }
    public var workingLabel: String {
        switch self {
        case .details: return "Reading your records…"
        case .conditions: return "Organizing your conditions…"
        case .overview: return "Updating your overview…"
        }
    }
    public var completionLabel: String {
        switch self {
        case .details: return "Details updated"
        case .conditions: return "Conditions updated"
        case .overview: return "Overview updated"
        }
    }
}

public enum SummaryUpdateState: Equatable, Sendable {
    case waiting, updating, ready, interrupted, needsAttention
}

/// Claims saved input versions once. A failed version requires an explicit retry;
/// a stopped version stays stopped across launches until new input or Resume.
public struct SummaryAutomaticUpdatePolicy: Sendable {
    private var attempted: Set<String> = []
    public var stoppedInput: String?
    public init(stoppedInput: String? = nil) { self.stoppedInput = stoppedInput }

    public func allows(_ input: String) -> Bool {
        stoppedInput != input && !attempted.contains(input)
    }
    public mutating func claim(_ input: String, explicitlyRequested: Bool = false) -> Bool {
        guard explicitlyRequested || allows(input) else { return false }
        if explicitlyRequested { stoppedInput = nil }
        attempted.insert(input)
        return true
    }
    public mutating func finished(_ input: String) { attempted.insert(input) }
    public mutating func interrupted(_ input: String) { attempted.remove(input) }
    public mutating func stop(_ input: String) { stoppedInput = input }
}
