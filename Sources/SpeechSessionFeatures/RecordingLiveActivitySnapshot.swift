import Foundation

/// Values the main app uses to drive the recording Live Activity.
public struct RecordingLiveActivitySnapshot: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case recording
        case paused
        case transcribing
    }

    public var isActive: Bool
    public var phase: Phase
    public var startedAt: Date?
    public var displayElapsed: TimeInterval
    public var accumulatedPausedSeconds: TimeInterval

    public init(
        isActive: Bool,
        phase: Phase,
        startedAt: Date?,
        displayElapsed: TimeInterval,
        accumulatedPausedSeconds: TimeInterval
    ) {
        self.isActive = isActive
        self.phase = phase
        self.startedAt = startedAt
        self.displayElapsed = displayElapsed
        self.accumulatedPausedSeconds = accumulatedPausedSeconds
    }
}
