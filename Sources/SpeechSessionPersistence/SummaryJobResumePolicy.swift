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
        processingIsAllowed: Bool,
        automaticResumeAlreadyAttempted: Bool = false
    ) -> Bool {
        hasPendingJob && hasLoaded && !isLaunching && !isProcessing && appIsActive
            && processingIsAllowed && !automaticResumeAlreadyAttempted
    }

    /// A record-processing pass is complete only when its durable records agree.
    /// The absence of an in-memory error is insufficient because cancellation can
    /// return after checkpointing an interrupted run without presenting an error.
    public static func recordJobCompleted(
        hasProcessingIssue: Bool,
        hasError: Bool,
        unfinishedRecordCount: Int,
        conditionOrganizationFailed: Bool
    ) -> Bool {
        !hasProcessingIssue && !hasError && unfinishedRecordCount == 0 && !conditionOrganizationFailed
    }
}
