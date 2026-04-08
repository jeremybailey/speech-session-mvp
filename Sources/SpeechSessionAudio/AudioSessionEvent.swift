import Foundation

/// High-level audio session notifications surfaced for the view model.
public enum AudioSessionEvent: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
}
