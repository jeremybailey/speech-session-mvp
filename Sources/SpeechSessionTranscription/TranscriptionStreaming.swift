import AVFoundation
import Foundation

/// Abstraction for live transcription backends (`SFSpeechRecognizer`, OpenAI Whisper, etc.).
public protocol TranscriptionStreaming: AnyObject, Sendable {
    var events: AsyncStream<TranscriptionEvent> { get }
    func beginStreaming(locale: Locale) throws
    func appendBuffer(_ buffer: AVAudioPCMBuffer)
    func endStreaming()
}

extension TranscriptionService: TranscriptionStreaming {}

/// Capture-only adapter: the durable recording is transcribed once after capture ends.
/// In particular, do not download a model or retain a second PCM copy while recording.
public final class SavedAudioTranscriptionCapture: TranscriptionStreaming, @unchecked Sendable {
    public let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation

    public init() {
        var continuation: AsyncStream<TranscriptionEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func beginStreaming(locale: Locale) throws {}
    public func appendBuffer(_ buffer: AVAudioPCMBuffer) {}
    public func endStreaming() { continuation.finish() }
}
