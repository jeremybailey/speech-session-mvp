/// A retained partial result is terminal work, not an unfinished paid request.
public enum WholeHistoryRecoveryPolicy {
    public static func requiresNewAttempt(generationTerminal: Bool, generationCompleted: Bool,
                                          overviewTerminal: Bool, overviewCompleted: Bool,
                                          retainedRecords: Int, canRevalidateSavedDetails: Bool = false) -> Bool {
        if canRevalidateSavedDetails { return false }
        return
        (generationTerminal && !generationCompleted) ||
        (generationCompleted && overviewTerminal && !overviewCompleted) ||
        (generationCompleted && overviewCompleted && retainedRecords > 0)
    }
}
