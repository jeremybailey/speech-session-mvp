/// A pending organization need is not evidence that a job is running. In
/// particular, imported history waits for an explicit user request.
public enum SummaryStoryLoadingPolicy {
    public static func showsPlaceholder(hasLoaded: Bool, needsConditionOrganization: Bool,
                                        isWorking: Bool, hasFailure: Bool) -> Bool {
        guard !hasFailure else { return false }
        return !hasLoaded || (needsConditionOrganization && isWorking)
    }
}
