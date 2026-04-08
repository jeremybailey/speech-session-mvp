import Foundation

public enum AudioRecordingError: Error, Equatable {
    case unsupportedPlatform
    case engineStartFailed
}
