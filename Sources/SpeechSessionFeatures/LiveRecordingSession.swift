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

    /// URL of the continuous recording file written during capture, if any.
    public var activeRecordingFileURL: URL? {
        audio.activeRecordingFileURL
    }

    /// Pauses microphone capture without closing the recording file.
    public func pauseCapture() {
        audio.pauseCapture()
    }

    /// Resumes microphone capture after an interruption or route change.
    public func resumeCapture() throws {
        try audio.resumeCapture()
    }

    /// Starts on-device streaming recognition, then microphone capture, forwarding PCM into the active recognition request.
    public func start(outputFileURL: URL? = nil, locale: Locale = .current) throws {
        try transcription.beginStreaming(locale: locale)
        do {
            try audio.startRecording(outputFileURL: outputFileURL) { [transcription] buffer in
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
