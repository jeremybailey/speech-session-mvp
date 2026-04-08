import Foundation

/// Which speech-to-text engine to use for a recording session (for comparison / testing).
public enum TranscriptionBackend: String, CaseIterable, Sendable {
    case onDeviceApple
    case openAIWhisper
    case onDeviceWhisperKit

    public var displayTitle: String {
        switch self {
        case .onDeviceApple:
            return "On-device (Apple Speech)"
        case .openAIWhisper:
            return "OpenAI Whisper (cloud)"
        case .onDeviceWhisperKit:
            return "On-device (WhisperKit)"
        }
    }
}
