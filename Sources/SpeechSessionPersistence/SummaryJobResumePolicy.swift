/// Decides whether an unfinished summary job should remain available for an
/// automatic foreground resume. Foreground failures stay user-controlled so a
/// persistent service error cannot create an automatic retry loop.
public enum SummaryJobResumePolicy {
    public static func shouldRetainPendingJob(
        completedSuccessfully: Bool,
        taskWasCancelled: Bool,
        wasBackgrounded: Bool,
        appIsActive: Bool
    ) -> Bool {
        guard !completedSuccessfully else { return false }
        return taskWasCancelled || wasBackgrounded || !appIsActive
    }

    public static func canResume(
        hasPendingJob: Bool,
        hasLoaded: Bool,
        isLaunching: Bool,
        isProcessing: Bool,
        appIsActive: Bool,
        processingIsAllowed: Bool
    ) -> Bool {
        hasPendingJob && hasLoaded && !isLaunching && !isProcessing && appIsActive && processingIsAllowed
    }
}
