import Foundation

#if os(iOS)
import AVFoundation

/// Captures microphone input via `AVAudioEngine` and forwards PCM buffers to a handler (e.g. speech recognition).
public final class AudioRecordingService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private let notificationCenter: NotificationCenter

    private var tapInstalled = false
    private var observersInstalled = false
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var notificationObservers: [NSObjectProtocol] = []

    /// Called on the main queue when interruptions or route changes occur.
    public var onSessionEvent: ((AudioSessionEvent) -> Void)?

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
    public func startRecording(onBuffer handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stopRecording()

        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: [])

        self.onBuffer = handler

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            self.onBuffer = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioRecordingError.engineStartFailed
        }

        installNotificationObserversIfNeeded()
    }

    /// Removes the tap, stops the engine, and deactivates the session.
    public func stopRecording() {
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        onBuffer = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
            ) { [weak self] _ in
                self?.onSessionEvent?(.routeChanged)
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

    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            onSessionEvent?(.interruptionBegan)
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            onSessionEvent?(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
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

    public init(notificationCenter: NotificationCenter = .default) {
        _ = notificationCenter
    }

    public static func requestRecordPermission() async -> Bool {
        false
    }

    public func startRecording(onBuffer handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        _ = handler
        throw AudioRecordingError.unsupportedPlatform
    }

    public func stopRecording() {}
}

#endif
