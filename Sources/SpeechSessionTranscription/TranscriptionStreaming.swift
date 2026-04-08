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
