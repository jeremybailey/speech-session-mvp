import Combine
import Foundation
import SpeechSessionAudio
import SpeechSessionPersistence
import SpeechSessionTranscription

@MainActor
public final class RecordingViewModel: ObservableObject {
    private let store: SessionStore
    private var pipeline: LiveRecordingSession?

    private var pendingBackend: TranscriptionBackend = .onDeviceWhisperKit
    private var pendingOpenAIKey: String = ""
    private var pendingOpenAIWhisperCredentials: OpenAIWhisperHTTPCredentials?
    private var pendingWhisperKitModel: String = DeviceCapabilityProfile.tinyWhisperKitModel
    private var experimentalWhisperKitUnlocked = false
    private var pendingEntryIntent: SessionEntryIntent = .clinicalVisit
    private var pendingFolderID: UUID?
    private var pendingRecordingSessionID: UUID?
    private var pendingRecordingFileURL: URL?

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
    private var totalPausedDuration: TimeInterval = 0
    private var pauseBeganAt: Date?

    @Published public private(set) var liveTranscript: String = ""
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var errorMessage: String?
    /// Whether the **current** recording uses Whisper (one cloud transcript after Stop, not live).
    @Published public private(set) var activeSessionUsesWhisper = false
    /// True while waiting for the post-stop Whisper upload (UI can show a spinner).
    @Published public private(set) var isFinishingWhisper = false
    /// True while transcribing a user-selected audio file.
    @Published public private(set) var isTranscribingFile = false
    /// True when system audio interrupted capture (call, Siri, etc.).
    @Published public private(set) var isCaptureInterrupted = false
    /// True when the app is not in the foreground while recording continues.
    @Published public private(set) var isAppInBackground = false
    /// Set to true by the event task when the transcription stream closes.
    private var transcriptionStreamFinished = false
    private var stopInProgress = false

    /// User-facing status for background or interrupted recording.
    public var recordingStatusMessage: String? {
        if isCaptureInterrupted {
            return "Paused — call or system audio"
        }
        if isAppInBackground, isRecording {
            return "Recording in background"
        }
        return nil
    }

    public func setAppInBackground(_ inBackground: Bool) {
        isAppInBackground = inBackground
    }

    /// Snapshot for lock-screen Live Activity updates.
    public var liveActivitySnapshot: RecordingLiveActivitySnapshot {
        let active = isRecording || isFinishingWhisper || isTranscribingFile
        let phase: RecordingLiveActivitySnapshot.Phase = {
            if isFinishingWhisper || isTranscribingFile { return .transcribing }
            if isCaptureInterrupted { return .paused }
            if isRecording { return .recording }
            return .recording
        }()

        var pausedNow: TimeInterval = 0
        if isCaptureInterrupted, let pauseBeganAt {
            pausedNow = Date().timeIntervalSince(pauseBeganAt)
        }

        return RecordingLiveActivitySnapshot(
            isActive: active,
            phase: phase,
            startedAt: recordingStartedAt,
            displayElapsed: elapsed,
            accumulatedPausedSeconds: totalPausedDuration + pausedNow
        )
    }

    public init(store: SessionStore) {
        self.store = store
    }

    /// Call from the UI before starting a recording so the chosen backend (and optional OpenAI proxy credentials / BYOK) apply.
    public func prepareForRecording(
        backend: TranscriptionBackend,
        openAIAPIKey: String,
        openAIWhisperCredentials: OpenAIWhisperHTTPCredentials? = nil,
        whisperKitModel: String = DeviceCapabilityProfile.tinyWhisperKitModel,
        experimentalWhisperKitUnlocked: Bool = false,
        entryIntent: SessionEntryIntent = .clinicalVisit,
        defaultFolderID: UUID? = nil
    ) {
        pendingBackend = backend
        pendingOpenAIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingOpenAIWhisperCredentials = openAIWhisperCredentials
        pendingWhisperKitModel = whisperKitModel
        self.experimentalWhisperKitUnlocked = experimentalWhisperKitUnlocked
        self.pendingEntryIntent = entryIntent
        pendingFolderID = defaultFolderID
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
        } catch RecordingStartError.missingOpenAIWhisperAccess {
            errorMessage = Self.openAIWhisperUnavailableMessage
            return
        } catch RecordingStartError.unsupportedWhisperKit(let message) {
            errorMessage = message
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
        totalPausedDuration = 0
        pauseBeganAt = nil
        isCaptureInterrupted = false
        isAppInBackground = false
        pendingRecordingSessionID = UUID()

        pipeline = sessionPipeline
        sessionPipeline.onAudioSessionEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleAudioSessionEvent(event)
            }
        }
        subscribeToEvents(sessionPipeline)
        activeSessionUsesWhisper = pendingBackend == .openAIWhisper || pendingBackend == .onDeviceWhisperKit

        do {
            let recordingURL: URL?
            if let sessionID = pendingRecordingSessionID {
                let storageDir = await store.storageDirectory
                let sourceStore = SessionSourceStore(storageDirectory: storageDir)
                let directory = sourceStore.sessionSourcesDirectory(sessionID: sessionID)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                recordingURL = directory.appendingPathComponent("recording.caf")
                pendingRecordingFileURL = recordingURL
            } else {
                recordingURL = nil
            }
            try sessionPipeline.start(outputFileURL: recordingURL, locale: locale)
            isRecording = true
            if let id = pendingRecordingSessionID, let recordingURL {
                var draft = Session(id: id, date: recordingStartedAt ?? Date(), transcript: "",
                    title: pendingEntryIntent == .personalJournal ? "Journal recording" : "Appointment recording",
                    entryIntent: pendingEntryIntent, folderID: pendingFolderID,
                    sourceAssets: [SessionSourceAsset(kind: .audio, relativePath: recordingURL.lastPathComponent, displayName: "Recording")])
                draft.processingState = .saved
                try await store.upsert(draft)
            }
            startTimer()
        } catch let error as TranscriptionServiceError {
            sessionPipeline.stop()
            eventTask?.cancel()
            isRecording = false
            activeSessionUsesWhisper = false
            pipeline = nil
            pendingRecordingSessionID = nil
            pendingRecordingFileURL = nil
            errorMessage = error.userFacingMessage
        } catch let error as AudioRecordingError {
            sessionPipeline.stop()
            eventTask?.cancel()
            isRecording = false
            activeSessionUsesWhisper = false
            pipeline = nil
            pendingRecordingSessionID = nil
            pendingRecordingFileURL = nil
            errorMessage = error.userFacingMessage
        } catch {
            sessionPipeline.stop()
            eventTask?.cancel()
            isRecording = false
            activeSessionUsesWhisper = false
            pipeline = nil
            pendingRecordingSessionID = nil
            pendingRecordingFileURL = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Stops the recording and returns the saved entry, or `nil` if saving failed.
    @discardableResult
    public func stop() async -> Session? {
        guard isRecording else { return nil }
        guard !stopInProgress else { return nil }
        stopInProgress = true
        defer { stopInProgress = false }

        let backend = pendingBackend
        let wasWhisper = activeSessionUsesWhisper
        let recordingURL = pendingRecordingFileURL

        timerTask?.cancel()
        timerTask = nil

        if wasWhisper {
            isFinishingWhisper = true
            errorMessage = nil
        }

        pipeline?.stop()
        isRecording = false
        isFinishingWhisper = true
        if let id = pendingRecordingSessionID {
            do { try await store.updateTranscript(sessionID: id, transcript: fullTranscriptForSave(), error: "The audio is saved. Transcription is being prepared; retry if it does not finish.") }
            catch { errorMessage = "Recording saved, but its processing status could not be updated." }
        }

        let transcript = await resolveFinalTranscript(
            recordingFileURL: recordingURL,
            backend: backend,
            wasWhisper: wasWhisper
        )

        eventTask?.cancel()
        eventTask = nil
        pipeline = nil

        isRecording = false
        isCaptureInterrupted = false
        isAppInBackground = false
        activeSessionUsesWhisper = false
        isFinishingWhisper = false

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, errorMessage == nil {
            errorMessage = "Transcription did not return a result."
        }

        let sessionID = pendingRecordingSessionID ?? UUID()
        var sourceAssets: [SessionSourceAsset]?
        if let recordingURL = pendingRecordingFileURL,
           FileManager.default.fileExists(atPath: recordingURL.path) {
            sourceAssets = [
                SessionSourceAsset(
                    kind: .audio,
                    relativePath: recordingURL.lastPathComponent,
                    displayName: "Recording"
                ),
            ]
        }
        pendingRecordingSessionID = nil
        pendingRecordingFileURL = nil

        var session = Session(
            id: sessionID,
            date: recordingStartedAt ?? Date(),
            transcript: transcript,
            entryIntent: pendingEntryIntent,
            folderID: pendingFolderID,
            sourceAssets: sourceAssets
        )
        session.processingState = finalTranscriptIncomplete || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failed : .ready
        session.processingError = session.processingState == .failed ? (errorMessage ?? "The audio is saved. The text may be incomplete; try reading the original again.") : nil
        recordingStartedAt = nil

        do {
            try await store.upsert(session)
        } catch {
            errorMessage = "Could not save entry."
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

    /// Transcribes an imported local audio file and saves it as a normal audio-backed entry.
    @discardableResult
    public func transcribeAudioFile(
        _ fileURL: URL,
        backend: TranscriptionBackend,
        openAIAPIKey: String,
        openAIWhisperCredentials: OpenAIWhisperHTTPCredentials? = nil,
        whisperKitModel: String = DeviceCapabilityProfile.tinyWhisperKitModel,
        locale: Locale = .current,
        experimentalWhisperKitUnlocked: Bool = false,
        entryIntent: SessionEntryIntent = .clinicalVisit,
        defaultFolderID: UUID? = nil
    ) async -> Session? {
        guard !isRecording, !isFinishingWhisper, !isTranscribingFile else {
            errorMessage = "Finish the current transcription before importing a file."
            return nil
        }

        errorMessage = nil
        isTranscribingFile = true
        defer { isTranscribingFile = false }

        let sessionID = UUID()
        var savedSession: Session?
        do {
            let storageDir = await store.storageDirectory
            let sourceStore = SessionSourceStore(storageDirectory: storageDir)
            let asset = try sourceStore.copyFile(from: fileURL, sessionID: sessionID,
                                                displayName: fileURL.lastPathComponent, kind: .audio)
            var draft = Session(id: sessionID, transcript: "", title: "Audio record",
                                inputType: .audio, entryIntent: entryIntent,
                                folderID: defaultFolderID, sourceAssets: [asset])
            draft.processingState = .transcribing
            try await store.upsert(draft)
            savedSession = draft
            let transcript: String
            switch backend {
            case .onDeviceApple:
                let speechStatus = await TranscriptionService.requestAuthorization()
                guard speechStatus == .authorized else {
                    throw AudioFileTranscriptionError.openAIError("Speech recognition not authorized. You can retry from the saved record.")
                }
                transcript = try await AudioFileTranscriptionService.transcribeWithAppleSpeech(
                    fileURL: fileURL,
                    locale: locale
                )

            case .openAIWhisper:
                if let creds = openAIWhisperCredentials {
                    transcript = try await AudioFileTranscriptionService.transcribeWithOpenAIWhisper(
                        fileURL: fileURL,
                        credentials: creds
                    )
                } else {
                    let key = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else {
                        throw AudioFileTranscriptionError.openAIError(Self.openAIWhisperUnavailableMessage)
                    }
                    transcript = try await AudioFileTranscriptionService.transcribeWithOpenAIWhisper(
                        fileURL: fileURL,
                        apiKey: key
                    )
                }

            case .onDeviceWhisperKit:
                let capability = DeviceCapabilityProfile.current
                guard capability.permitsWhisperKit(experimentalUnlocked: experimentalWhisperKitUnlocked),
                      capability.permitsWhisperKitModel(whisperKitModel, experimentalUnlocked: experimentalWhisperKitUnlocked)
                else {
                    throw AudioFileTranscriptionError.openAIError(capability.whisperKitHardBlockReason(experimentalUnlocked: experimentalWhisperKitUnlocked)
                        ?? "This WhisperKit model is not available on this iPhone.")
                }
                transcript = try await AudioFileTranscriptionService.transcribeWithWhisperKit(
                    fileURL: fileURL,
                    modelName: whisperKitModel
                )
            }

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AudioFileTranscriptionError.emptyTranscript
            }

            try await store.updateTranscript(sessionID: sessionID, transcript: trimmed, error: nil)
            savedSession?.transcript = trimmed
            savedSession?.processingState = .ready
            return savedSession
        } catch {
            errorMessage = error.localizedDescription
            if savedSession != nil {
                do { try await store.updateTranscript(sessionID: sessionID, transcript: (error as? PartialAudioTranscriptionError)?.transcript, error: error.localizedDescription) }
                catch { errorMessage = "The original was saved, but processing status could not be updated." }
                if let partial = error as? PartialAudioTranscriptionError { savedSession?.transcript = partial.transcript }
                savedSession?.processingState = .failed
                savedSession?.processingError = error.localizedDescription
                return savedSession
            }
            return nil
        }
    }

    private func makePipeline() throws -> LiveRecordingSession {
        switch pendingBackend {
        case .onDeviceApple:
            return LiveRecordingSession(transcription: TranscriptionService())
        case .openAIWhisper:
            if let creds = pendingOpenAIWhisperCredentials {
                return LiveRecordingSession(transcription: WhisperTranscriptionService(credentials: creds))
            }
            guard !pendingOpenAIKey.isEmpty else {
                throw RecordingStartError.missingOpenAIWhisperAccess
            }
            return LiveRecordingSession(transcription: WhisperTranscriptionService(apiKey: pendingOpenAIKey))
        case .onDeviceWhisperKit:
            let capability = DeviceCapabilityProfile.current
            guard capability.permitsWhisperKit(experimentalUnlocked: experimentalWhisperKitUnlocked),
                  capability.permitsWhisperKitModel(pendingWhisperKitModel, experimentalUnlocked: experimentalWhisperKitUnlocked)
            else {
                throw RecordingStartError.unsupportedWhisperKit(
                    capability.whisperKitHardBlockReason(experimentalUnlocked: experimentalWhisperKitUnlocked)
                        ?? "This WhisperKit model is not available on this iPhone."
                )
            }
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

    private func handleAudioSessionEvent(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            isCaptureInterrupted = true
            if pauseBeganAt == nil {
                pauseBeganAt = Date()
            }
        case .interruptionEnded(let shouldResume):
            guard shouldResume else { return }
            resumeElapsedAfterPause()
            isCaptureInterrupted = false
        case .routeChanged, .mediaServicesReset:
            resumeElapsedAfterPause()
            isCaptureInterrupted = false
        }
    }

    private func resumeElapsedAfterPause() {
        if let pauseBeganAt {
            totalPausedDuration += Date().timeIntervalSince(pauseBeganAt)
            self.pauseBeganAt = nil
        }
    }

    private var finalTranscriptIncomplete = false

    private func resolveFinalTranscript(
        recordingFileURL: URL?,
        backend: TranscriptionBackend,
        wasWhisper: Bool
    ) async -> String {
        let live = fullTranscriptForSave()
        finalTranscriptIncomplete = false
        // Preserve the working live Apple path; a second recognition pass must not invalidate it.
        if backend == .onDeviceApple, !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return live
        }
        var fileFailure: Error?
        var partialFileText = ""
        if let recordingFileURL, FileManager.default.fileExists(atPath: recordingFileURL.path) {
            do {
                let text = try await transcribeStoredRecordingFile(recordingFileURL)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = nil
                    return text
                }
            } catch {
                fileFailure = error
                partialFileText = (error as? PartialAudioTranscriptionError)?.transcript ?? ""
            }
        }

        if wasWhisper {
            let deadline = Date().addingTimeInterval(120)
            while !Task.isCancelled && Date() < deadline {
                let current = fullTranscriptForSave()
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Prefer a partial full-file transcript over the batch backend's capped audio buffer.
                    if partialFileText.isEmpty {
                        errorMessage = nil
                        return current
                    }
                    break
                }
                if errorMessage != nil || transcriptionStreamFinished { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        finalTranscriptIncomplete = true
        if let fileFailure {
            errorMessage = "The full recording could not be transcribed: \(fileFailure.localizedDescription) Your audio and partial text are saved. Open the original record and try reading it again."
        }
        return partialFileText.isEmpty ? fullTranscriptForSave() : partialFileText
    }

    private func transcribeStoredRecordingFile(_ fileURL: URL) async throws -> String {
        switch pendingBackend {
        case .onDeviceApple:
            return try await AudioFileTranscriptionService.transcribeWithAppleSpeech(
                fileURL: fileURL,
                locale: .current
            )
        case .openAIWhisper:
            if let creds = pendingOpenAIWhisperCredentials {
                return try await AudioFileTranscriptionService.transcribeWithOpenAIWhisper(
                    fileURL: fileURL,
                    credentials: creds
                )
            }
            return try await AudioFileTranscriptionService.transcribeWithOpenAIWhisper(
                fileURL: fileURL,
                apiKey: pendingOpenAIKey
            )
        case .onDeviceWhisperKit:
            return try await AudioFileTranscriptionService.transcribeWithWhisperKit(
                fileURL: fileURL,
                modelName: pendingWhisperKitModel
            )
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
                var pausedNow: TimeInterval = 0
                if self.isCaptureInterrupted, let pauseBeganAt = self.pauseBeganAt {
                    pausedNow = Date().timeIntervalSince(pauseBeganAt)
                }
                self.elapsed = Date().timeIntervalSince(start) - self.totalPausedDuration - pausedNow
            }
        }
    }

    private static var openAIWhisperUnavailableMessage: String {
        var s = "Cloud transcription requires signing in under Settings → Account, with your organization’s API URL configured."
        #if DEBUG
        s += " Debug builds can also paste an OpenAI API key in Settings."
        #endif
        return s
    }
}

// MARK: - Errors

private enum RecordingStartError: Error {
    case missingOpenAIWhisperAccess
    case unsupportedWhisperKit(String)
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
