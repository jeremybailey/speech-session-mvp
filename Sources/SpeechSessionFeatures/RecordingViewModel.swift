import Combine
import Foundation
import SpeechSessionAudio
import SpeechSessionPersistence
import SpeechSessionTranscription

@MainActor
public final class RecordingViewModel: ObservableObject {
    private let store: SessionStore
    private var pipeline: LiveRecordingSession?

    private var pendingBackend: TranscriptionBackend = .onDeviceApple
    private var pendingOpenAIKey: String = ""
    private var pendingWhisperKitModel: String = "openai_whisper-base.en"

    private var committedText = ""
    private var partialTail = ""
    /// Time of the last non-empty partial; used to detect a pause → new utterance without duplicating cumulative partials.
    private var lastNonEmptyPartialAt: Date?
    /// Recent text we moved into `committedText` on a pause; used to skip within-chunk duplicate pins.
    private var recentPinnedUtterances: [String] = []
    /// Length (in `String.Index` terms via `count`) of `committedText` that belongs to *already-finalized* chunks.
    /// When a new `chunkFinalized` event arrives, everything from this offset onward is replaced with the
    /// accurate finalized text, eliminating double-appends from previously pinned partials.
    private var frozenCommittedLength = 0
    private var recordingStartedAt: Date?
    private var eventTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    @Published public private(set) var liveTranscript: String = ""
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var errorMessage: String?
    /// Whether the **current** recording uses Whisper (one cloud transcript after Stop, not live).
    @Published public private(set) var activeSessionUsesWhisper = false
    /// True while waiting for the post-stop Whisper upload (UI can show a spinner).
    @Published public private(set) var isFinishingWhisper = false
    /// Set to true by the event task when the transcription stream closes.
    private var transcriptionStreamFinished = false

    public init(store: SessionStore) {
        self.store = store
    }

    /// Call from the UI before presenting the recording screen so the chosen backend and API key apply.
    public func prepareForRecording(
        backend: TranscriptionBackend,
        openAIAPIKey: String,
        whisperKitModel: String = "openai_whisper-base.en"
    ) {
        pendingBackend = backend
        pendingOpenAIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingWhisperKitModel = whisperKitModel
    }

    deinit {
        eventTask?.cancel()
        timerTask?.cancel()
    }

    public func start(locale: Locale = .current) async {
        errorMessage = nil
        activeSessionUsesWhisper = false

        let micGranted = await AudioRecordingService.requestRecordPermission()
        guard micGranted else {
            errorMessage = "Microphone access denied."
            return
        }

        if pendingBackend == .onDeviceApple {
            let speechStatus = await TranscriptionService.requestAuthorization()
            guard speechStatus == .authorized else {
                errorMessage = "Speech recognition not authorized."
                return
            }
        }

        let sessionPipeline: LiveRecordingSession
        do {
            sessionPipeline = try makePipeline()
        } catch RecordingStartError.missingOpenAIAPIKey {
            errorMessage = "Add an OpenAI API key in Transcription (testing) to use Whisper."
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        committedText = ""
        partialTail = ""
        lastNonEmptyPartialAt = nil
        recentPinnedUtterances = []
        frozenCommittedLength = 0
        updateLiveDisplay()
        recordingStartedAt = Date()
        elapsed = 0

        pipeline = sessionPipeline
        subscribeToEvents(sessionPipeline)
        activeSessionUsesWhisper = pendingBackend == .openAIWhisper || pendingBackend == .onDeviceWhisperKit

        do {
            try sessionPipeline.start(locale: locale)
            isRecording = true
            startTimer()
        } catch let error as TranscriptionServiceError {
            isRecording = false
            activeSessionUsesWhisper = false
            pipeline = nil
            errorMessage = error.userFacingMessage
        } catch let error as AudioRecordingError {
            isRecording = false
            activeSessionUsesWhisper = false
            pipeline = nil
            errorMessage = error.userFacingMessage
        } catch {
            isRecording = false
            activeSessionUsesWhisper = false
            pipeline = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Stops the recording and returns the saved session, or `nil` if saving failed.
    @discardableResult
    public func stop() async -> Session? {
        let wasWhisper = activeSessionUsesWhisper
        isFinishingWhisper = wasWhisper
        if wasWhisper {
            errorMessage = nil
        }
        timerTask?.cancel()
        timerTask = nil
        pipeline?.stop()

        if wasWhisper {
            // Wait until the batch backend yields a result/error, the stream closes,
            // or we hit the safety timeout — whichever comes first.
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if let e = errorMessage, !e.isEmpty { break }
                if !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                if transcriptionStreamFinished { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if errorMessage == nil,
               liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                errorMessage = "Transcription did not return a result."
            }
        }

        eventTask?.cancel()
        eventTask = nil
        pipeline = nil
        isRecording = false
        activeSessionUsesWhisper = false
        isFinishingWhisper = false

        let transcript = fullTranscriptForSave()
        let session = Session(
            date: recordingStartedAt ?? Date(),
            transcript: transcript
        )
        recordingStartedAt = nil

        do {
            try await store.upsert(session)
        } catch {
            errorMessage = "Could not save session."
            committedText = ""
            partialTail = ""
            lastNonEmptyPartialAt = nil
            recentPinnedUtterances = []
            frozenCommittedLength = 0
            updateLiveDisplay()
            elapsed = 0
            return nil
        }

        committedText = ""
        partialTail = ""
        lastNonEmptyPartialAt = nil
        recentPinnedUtterances = []
        frozenCommittedLength = 0
        updateLiveDisplay()
        elapsed = 0
        return session
    }

    private func makePipeline() throws -> LiveRecordingSession {
        switch pendingBackend {
        case .onDeviceApple:
            return LiveRecordingSession(transcription: TranscriptionService())
        case .openAIWhisper:
            guard !pendingOpenAIKey.isEmpty else {
                throw RecordingStartError.missingOpenAIAPIKey
            }
            return LiveRecordingSession(transcription: WhisperTranscriptionService(apiKey: pendingOpenAIKey))
        case .onDeviceWhisperKit:
            return LiveRecordingSession(transcription: WhisperKitTranscriptionService(modelName: pendingWhisperKitModel))
        }
    }

    private func subscribeToEvents(_ sessionPipeline: LiveRecordingSession) {
        eventTask?.cancel()
        transcriptionStreamFinished = false
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in sessionPipeline.transcriptionEvents {
                self.handleTranscriptionEvent(event)
            }
            // Stream closed — unblock the stop() wait loop.
            self.transcriptionStreamFinished = true
        }
    }

    private func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let text):
            applyPartialHypothesis(text)
        case .chunkFinalized(let text):
            if !partialTail.isEmpty {
                // Apple Speech (live streaming): use the pinned partial tail rather than ASR's
                // lastHypothesis, which may be shorter due to backward revision. Append-only.
                let t = partialTail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !committedAlreadyCoversTailPhrase(t) {
                    commitPartialTailToCommitted(t)
                }
            } else {
                // Batch backends (OpenAI Whisper, WhisperKit): no live partials — all text
                // arrives here at the end of the recording. Append it directly.
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    commitPartialTailToCommitted(t)
                }
            }
            frozenCommittedLength = committedText.count
            recentPinnedUtterances.removeAll()
            partialTail = ""
            lastNonEmptyPartialAt = nil
            updateLiveDisplay()
        case .error(let message):
            errorMessage = message
        }
    }

    private func updateLiveDisplay() {
        if partialTail.isEmpty {
            liveTranscript = committedText
        } else if committedText.isEmpty {
            liveTranscript = partialTail
        } else {
            liveTranscript = committedText + "\n\n" + partialTail
        }
    }

    /// SFSpeechRecognizer partials are cumulative from the chunk start. When we've already pinned some
    /// utterances into `committedText` within this chunk, the next partial re-includes that text. Strip
    /// it so we only keep the novel suffix and avoid displaying duplicates.
    private func stripCurrentChunkPrefix(from text: String) -> String {
        let p = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, frozenCommittedLength < committedText.count else { return p }
        let currentChunkCommitted = String(committedText.dropFirst(frozenCommittedLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentChunkCommitted.isEmpty else { return p }
        let lp = p.lowercased()
        let lc = currentChunkCommitted.lowercased()
        if lp.hasPrefix(lc) {
            let suffix = String(p.dropFirst(currentChunkCommitted.count))
                .trimmingCharacters(in: .whitespaces)
            return suffix
        }
        return p
    }

    /// Partials are cumulative within one utterance → **replace** `partialTail`. After a **pause**, Speech
    /// often sends a fresh hypothesis that would **wipe** the prior line; we **pin** the old tail into
    /// `committedText` first, then show only the new utterance in `partialTail` (avoids both wipe and runaway concat).
    private func applyPartialHypothesis(_ text: String) {
        let inc = stripCurrentChunkPrefix(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        if inc.isEmpty {
            updateLiveDisplay()
            return
        }

        let now = Date()
        let gap = lastNonEmptyPartialAt.map { now.timeIntervalSince($0) } ?? 0
        defer { lastNonEmptyPartialAt = now }

        let prev = partialTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if prev.isEmpty {
            partialTail = text
            updateLiveDisplay()
            return
        }

        if shouldPinPreviousBeforeNewHypothesis(previous: prev, incoming: inc, gapSinceLastPartial: gap) {
            commitPinnedUtterance(prev)
            partialTail = text
        } else {
            partialTail = text
        }
        updateLiveDisplay()
    }

    /// Short gaps are normal between cumulative updates; longer gaps + unrelated text mean a new spoken phrase.
    private let pauseSuggestsNewUtteranceSeconds: TimeInterval = 0.55

    private func commitPartialTailToCommitted(_ previousTrimmed: String) {
        let t = previousTrimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if committedText.isEmpty {
            committedText = t
        } else {
            committedText += "\n\n" + t
        }
    }

    private func commitPinnedUtterance(_ previousTrimmed: String) {
        let t = previousTrimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !committedAlreadyCoversTailPhrase(t) {
            commitPartialTailToCommitted(t)
        }
        recentPinnedUtterances.append(t)
        let maxPins = 4
        if recentPinnedUtterances.count > maxPins {
            recentPinnedUtterances.removeFirst(recentPinnedUtterances.count - maxPins)
        }
    }

    /// If `true`, move `previous` into committed storage — `incoming` is the start of a new utterance, not an extension.
    private func shouldPinPreviousBeforeNewHypothesis(
        previous: String,
        incoming: String,
        gapSinceLastPartial: TimeInterval
    ) -> Bool {
        guard gapSinceLastPartial >= pauseSuggestsNewUtteranceSeconds else { return false }

        let p = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let i = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || i.isEmpty { return false }

        if i.hasPrefix(p) || p.hasPrefix(i) { return false }
        let lp = p.lowercased()
        let li = i.lowercased()
        if li.hasPrefix(lp) || lp.hasPrefix(li) { return false }

        if i.contains(p) { return false }

        return true
    }

/// True if `phrase` already appears at the end of `committedText` (substring or fuzzy), so we should not add it again.
    private func committedAlreadyCoversTailPhrase(_ phrase: String) -> Bool {
        let t = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 22, !committedText.isEmpty else { return false }
        let tl = t.lowercased()
        let window = min(committedText.count, max(t.count * 2 + 100, 360))
        let suf = String(committedText.suffix(window)).lowercased()
        if suf.contains(tl) { return true }
        return false
    }

    /// True when `finalized` is the same spoken phrase as `pinned` (wording may differ slightly).
    private func isRoughlyDuplicateUtterance(_ pinned: String, _ finalized: String) -> Bool {
        let a = pinned.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }

        let la = a.lowercased()
        let lb = b.lowercased()
        if la == lb { return true }

        let minLong = 28
        if la.count >= minLong, lb.count >= minLong {
            if la.contains(lb) || lb.contains(la) { return true }
        }

        let fa = alphanumericFold(la)
        let fb = alphanumericFold(lb)
        if fa.count >= 40, fb.count >= 40 {
            if fa.contains(fb) || fb.contains(fa) { return true }
        }

        let ta = wordTokens(la)
        let tb = wordTokens(lb)
        let inter = ta.intersection(tb).count
        let uni = ta.union(tb).count
        if min(ta.count, tb.count) >= 8, uni >= 14, Double(inter) / Double(uni) >= 0.62 {
            return true
        }

        let aa = Array(la)
        let ba = Array(lb)
        var prefix = 0
        while prefix < min(aa.count, ba.count), aa[prefix] == ba[prefix] { prefix += 1 }
        var suffix = 0
        var i = aa.count - 1
        var j = ba.count - 1
        while i >= 0, j >= 0, aa[i] == ba[j] {
            suffix += 1
            i -= 1
            j -= 1
        }
        let shorter = min(aa.count, ba.count)
        guard shorter >= 16 else { return false }
        let best = max(prefix, suffix)
        return Double(best) / Double(shorter) >= 0.78
    }

    private func alphanumericFold(_ s: String) -> String {
        s.filter { $0.isLetter || $0.isNumber }
    }

    private func wordTokens(_ s: String) -> Set<String> {
        let parts = s.components(separatedBy: .whitespacesAndNewlines)
        return Set(
            parts.map { $0.filter { $0.isLetter || $0.isNumber }.lowercased() }.filter { $0.count > 1 }
        )
    }

    private func fullTranscriptForSave() -> String {
        let merged = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return merged
    }

    private func startTimer() {
        timerTask?.cancel()
        let start = Date()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isRecording else { break }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }
}

// MARK: - Errors

private enum RecordingStartError: Error {
    case missingOpenAIAPIKey
}

private extension TranscriptionServiceError {
    var userFacingMessage: String {
        switch self {
        case .noRecognizer:
            return "Speech recognizer is not available for this language."
        case .onDeviceNotSupported:
            return "On-device speech recognition is not supported on this device."
        case .alreadyStreaming:
            return "Recording is already active."
        }
    }
}

private extension AudioRecordingError {
    var userFacingMessage: String {
        switch self {
        case .unsupportedPlatform:
            return "Recording is only supported on iOS."
        case .engineStartFailed:
            return "Could not start audio capture."
        }
    }
}
