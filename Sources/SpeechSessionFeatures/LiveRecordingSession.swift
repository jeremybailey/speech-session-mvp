import Foundation
import SpeechSessionAudio
import SpeechSessionTranscription

/// Owns audio capture and speech recognition and connects the tap to `appendBuffer` so callers do not wire buffers manually.
public final class LiveRecordingSession: @unchecked Sendable {
    private let audio: AudioRecordingService
    private let transcription: TranscriptionStreaming

    public init(
        audio: AudioRecordingService = AudioRecordingService(),
        transcription: TranscriptionStreaming
    ) {
        self.audio = audio
        self.transcription = transcription
    }

    public var transcriptionEvents: AsyncStream<TranscriptionEvent> {
        transcription.events
    }

    public var onAudioSessionEvent: ((AudioSessionEvent) -> Void)? {
        get { audio.onSessionEvent }
        set { audio.onSessionEvent = newValue }
    }

    /// Starts on-device streaming recognition, then microphone capture, forwarding PCM into the active recognition request.
    public func start(locale: Locale = .current) throws {
        try transcription.beginStreaming(locale: locale)
        do {
            try audio.startRecording { [transcription] buffer in
                transcription.appendBuffer(buffer)
            }
        } catch {
            transcription.endStreaming()
            throw error
        }
    }

    /// Stops capture first, then ends recognition (order avoids appending after teardown).
    public func stop() {
        audio.stopRecording()
        transcription.endStreaming()
    }
}
