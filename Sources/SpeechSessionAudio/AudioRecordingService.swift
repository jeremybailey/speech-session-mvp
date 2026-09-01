import Foundation

#if os(iOS)
import AVFoundation

/// Captures microphone input via `AVAudioEngine` and forwards PCM buffers to a handler (e.g. speech recognition).
public final class AudioRecordingService: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private let notificationCenter: NotificationCenter

    private var tapInstalled = false
    private var observersInstalled = false
    private var captureActive = false
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var notificationObservers: [NSObjectProtocol] = []
    private var audioFile: AVAudioFile?
    private var recordingFileURL: URL?

    /// Called on the main queue when interruptions or route changes occur.
    public var onSessionEvent: ((AudioSessionEvent) -> Void)?

    /// URL of the file being written during the current recording, if any.
    public var activeRecordingFileURL: URL? { recordingFileURL }

    /// True while capture is active (including paused-for-interruption states).
    public var isCaptureActive: Bool { captureActive }

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    deinit {
        removeNotificationObservers()
        stopRecording()
    }

    // MARK: - Permissions

    public static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Capture

    /// Installs the input tap and starts the engine. Stops any prior recording first.
    public func startRecording(
        outputFileURL: URL? = nil,
        onBuffer handler: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        stopRecording()

        try configureSession()
        self.onBuffer = handler
        captureActive = true

        if let outputFileURL {
            let directory = outputFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            recordingFileURL = outputFileURL
        }

        try startEngineTapAndFileWriter()

        installNotificationObserversIfNeeded()
    }

    /// Stops the engine tap but keeps the file open and handler wired for resume.
    public func pauseCapture() {
        guard captureActive else { return }
        removeTapAndStopEngine()
    }

    /// Restarts the engine tap after an interruption or route change.
    public func resumeCapture() throws {
        guard captureActive, onBuffer != nil else { return }
        try configureSession()
        try startEngineTapAndFileWriter()
    }

    /// Removes the tap, stops the engine, and deactivates the session.
    @discardableResult
    public func stopRecording() -> URL? {
        let savedURL = recordingFileURL
        captureActive = false
        audioFile = nil
        recordingFileURL = nil
        removeTapAndStopEngine()
        onBuffer = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return savedURL
    }

    // MARK: - Engine

    private func configureSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: [])
    }

    private func startEngineTapAndFileWriter() throws {
        removeTapAndStopEngine()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        if audioFile == nil, let recordingFileURL {
            audioFile = try AVAudioFile(forWriting: recordingFileURL, settings: format.settings)
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            if let audioFile = self.audioFile {
                try? audioFile.write(from: buffer)
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AudioRecordingError.engineStartFailed
        }
    }

    private func removeTapAndStopEngine() {
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    private func rebuildEngineAndResume() {
        removeTapAndStopEngine()
        engine = AVAudioEngine()
        do {
            try resumeCapture()
        } catch {
            onSessionEvent?(.interruptionBegan)
        }
    }

    // MARK: - Notifications

    private func installNotificationObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        let mainQueue = OperationQueue.main

        notificationObservers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: mainQueue
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        )

        notificationObservers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: mainQueue
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        )

        notificationObservers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: mainQueue
            ) { [weak self] _ in
                guard let self, self.captureActive else { return }
                self.onSessionEvent?(.mediaServicesReset)
                self.rebuildEngineAndResume()
            }
        )
    }

    private func removeNotificationObservers() {
        for token in notificationObservers {
            notificationCenter.removeObserver(token)
        }
        notificationObservers.removeAll()
        observersInstalled = false
    }

    private func handleRouteChange(_ notification: Notification) {
        guard captureActive else { return }

        let reason: AVAudioSession.RouteChangeReason? = {
            guard
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            else { return nil }
            return AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        }()

        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .wakeFromSleep:
            onSessionEvent?(.routeChanged)
            rebuildEngineAndResume()
        case .categoryChange, .override, .routeConfigurationChange, .noSuitableRouteForCategory, .unknown:
            // Category/route updates happen during normal session setup — do not restart capture.
            break
        case nil:
            onSessionEvent?(.routeChanged)
        @unknown default:
            onSessionEvent?(.routeChanged)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            pauseCapture()
            onSessionEvent?(.interruptionBegan)
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            onSessionEvent?(.interruptionEnded(shouldResume: shouldResume))
            if shouldResume, captureActive {
                rebuildEngineAndResume()
            }
        @unknown default:
            break
        }
    }
}

#else

import AVFoundation

/// Stub: real capture is implemented for iOS only; macOS builds use this for package compatibility.
public final class AudioRecordingService: @unchecked Sendable {
    public var onSessionEvent: ((AudioSessionEvent) -> Void)?
    public var activeRecordingFileURL: URL? { nil }
    public var isCaptureActive: Bool { false }

    public init(notificationCenter: NotificationCenter = .default) {
        _ = notificationCenter
    }

    public static func requestRecordPermission() async -> Bool {
        false
    }

    public func startRecording(
        outputFileURL: URL? = nil,
        onBuffer handler: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        _ = outputFileURL
        _ = handler
        throw AudioRecordingError.unsupportedPlatform
    }

    public func pauseCapture() {}

    public func resumeCapture() throws {
        throw AudioRecordingError.unsupportedPlatform
    }

    @discardableResult
    public func stopRecording() -> URL? { nil }
}

#endif
