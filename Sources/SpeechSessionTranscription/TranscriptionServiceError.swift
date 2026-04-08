import Foundation

public enum TranscriptionServiceError: Error, Equatable {
    case noRecognizer
    case onDeviceNotSupported
    case alreadyStreaming
}
