import Foundation

/// Writing aims for <=100 words; small overruns are presentation, not source failures.
/// Keep a finite display ceiling without changing citation, coverage or number checks.
public enum WholeHistoryOverviewDisplay {
    public static func withinCharacterLimit(_ text: String, compact: Bool, balanced: Bool) -> Bool {
        text.count <= (compact ? 850 : (balanced ? 1200 : 1000))
    }
    public static func withinWordLimit(_ text: String, compact: Bool, balanced: Bool) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).count <= (compact || balanced ? 150 : 130)
    }
}
