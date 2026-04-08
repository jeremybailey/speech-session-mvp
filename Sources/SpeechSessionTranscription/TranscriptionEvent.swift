import Foundation

/// Events emitted while streaming audio into on-device speech recognition.
public enum TranscriptionEvent: Sendable, Equatable {
    /// Hypothesis for the active chunk; replaces previous partials until finalized.
    case partial(String)
    /// A finalized segment from the recognizer (utterance final or end of a rotated chunk).
    case chunkFinalized(String)
    /// Recoverable or informational error; the service may continue or restart a chunk.
    case error(String)
}
