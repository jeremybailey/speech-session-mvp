import AVFoundation
import Foundation
import Speech

/// Streams microphone PCM buffers to on-device `SFSpeechRecognizer`, with timed chunk rotation for long sessions.
///
/// - Important: Call `appendBuffer` only from the audio tap; it uses a serial queue with `sync` so buffers are
///   appended before the engine reuses them. Do not perform work that waits on the main thread inside the tap.
public final class TranscriptionService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpeechSessionTranscription.service")
    private let chunkInterval: TimeInterval
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var rotationWorkItem: DispatchWorkItem?

    private var isStreaming = false
    private var awaitingTeardown = false
    /// Latest non-empty hypothesis for the active chunk (used when rotation ends with an error or no final result).
    private var lastNonEmptyHypothesisInChunk = ""

    public let events: AsyncStream<TranscriptionEvent>

    /// - Parameter chunkInterval: How often to end the current recognition request and start a new one (long-session stability).
    public init(chunkInterval: TimeInterval = 50) {
        self.chunkInterval = chunkInterval
        let (stream, continuation) = AsyncStream<TranscriptionEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        queue.sync {
            isStreaming = false
            awaitingTeardown = false
            rotationWorkItem?.cancel()
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            speechRecognizer = nil
        }
        continuation.finish()
    }

    // MARK: - Authorization

    public static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    @MainActor
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts streaming recognition. Throws if on-device recognition is not supported for `locale`.
    public func beginStreaming(locale: Locale = .current) throws {
        try queue.sync {
            guard !isStreaming else {
                throw TranscriptionServiceError.alreadyStreaming
            }
            let recognizer = SFSpeechRecognizer(locale: locale)
            guard let recognizer else {
                throw TranscriptionServiceError.noRecognizer
            }
            guard recognizer.supportsOnDeviceRecognition else {
                throw TranscriptionServiceError.onDeviceNotSupported
            }
            speechRecognizer = recognizer
            isStreaming = true
            awaitingTeardown = false
            startNewChunkLocked()
            scheduleNextRotationLocked()
        }
    }

    /// Appends audio to the current recognition request. Safe to call from the audio tap; executes synchronously on the service queue.
    public func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard !awaitingTeardown, let request = recognitionRequest else { return }
            request.append(buffer)
        }
    }

    /// Stops recognition, cancels rotation, and clears speech resources.
    public func endStreaming() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStreaming = false
            self.awaitingTeardown = false
            self.rotationWorkItem?.cancel()
            self.rotationWorkItem = nil
            self.recognitionRequest?.endAudio()
            self.recognitionRequest = nil
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.speechRecognizer = nil
        }
    }

    // MARK: - Internals

    private func scheduleNextRotationLocked() {
        guard isStreaming else { return }
        rotationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isStreaming else { return }
            self.awaitingTeardown = true
            self.recognitionRequest?.endAudio()
        }
        rotationWorkItem = item
        queue.asyncAfter(deadline: .now() + chunkInterval, execute: item)
    }

    private func startNewChunkLocked() {
        guard isStreaming else { return }
        lastNonEmptyHypothesisInChunk = ""
        guard let speechRecognizer else {
            continuation.yield(.error("Speech recognizer missing"))
            isStreaming = false
            return
        }
        guard speechRecognizer.isAvailable else {
            continuation.yield(.error("Speech recognizer unavailable"))
            isStreaming = false
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async { self.handleRecognition(result: result, error: error) }
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if awaitingTeardown {
            if let result {
                let text = result.bestTranscription.formattedString
                rememberHypothesisIfNonEmpty(text)
                if result.isFinal {
                    awaitingTeardown = false
                    finishTeardownAfterRotation(lastResult: text)
                    return
                }
                if !text.isEmpty {
                    continuation.yield(.partial(text))
                }
            }
            if error != nil {
                awaitingTeardown = false
                finishTeardownAfterRotation(lastResult: nil)
            }
            return
        }

        if let result {
            let text = result.bestTranscription.formattedString
            rememberHypothesisIfNonEmpty(text)
            if result.isFinal {
                if !text.isEmpty {
                    continuation.yield(.chunkFinalized(text))
                }
            } else if !text.isEmpty {
                continuation.yield(.partial(text))
            }
        }

        if let error, result == nil, isStreaming, !awaitingTeardown {
            let fb = lastNonEmptyHypothesisInChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fb.isEmpty {
                continuation.yield(.chunkFinalized(fb))
            }
            lastNonEmptyHypothesisInChunk = ""
            continuation.yield(.error(error.localizedDescription))
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            startNewChunkLocked()
            scheduleNextRotationLocked()
        }
    }

    private func finishTeardownAfterRotation(lastResult: String?) {
        let primary = lastResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = lastNonEmptyHypothesisInChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty {
            continuation.yield(.chunkFinalized(primary))
        } else if !fallback.isEmpty {
            continuation.yield(.chunkFinalized(fallback))
        }
        lastNonEmptyHypothesisInChunk = ""
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if isStreaming {
            startNewChunkLocked()
            scheduleNextRotationLocked()
        }
    }

    private func rememberHypothesisIfNonEmpty(_ text: String) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastNonEmptyHypothesisInChunk = text
        }
    }
}
