import Combine
import Foundation
import SpeechSessionFeatures
import SpeechSessionPersistence

extension Notification.Name {
    static let sharedAudioURLReceived = Notification.Name("SpeechSessionSharedAudioURLReceived")
}

@MainActor
final class SharedAudioURLInbox {
    static let shared = SharedAudioURLInbox()

    private let appGroupID = "group.com.CollectiveCare.pilot"
    private let sharedImportsDirectoryName = "SharedAudioImports"
    private var pendingURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        if url.scheme == "collectivecare", url.host == "share-debug" {
            return
        }

        let resolvedURL = resolveHandoffURL(url) ?? url
        pendingURLs.append(resolvedURL)
        NotificationCenter.default.post(name: .sharedAudioURLReceived, object: resolvedURL)
    }

    func drain() -> [URL] {
        defer { pendingURLs.removeAll() }
        return pendingURLs
    }

    func enqueueNextSharedImportIfAvailable() {
        guard let nextURL = nextSharedImportURL() else {
            return
        }
        enqueue(nextURL)
    }

    private func resolveHandoffURL(_ url: URL) -> URL? {
        guard url.scheme == "collectivecare",
              url.host == "share-import",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fileName = components.queryItems?.first(where: { $0.name == "file" })?.value,
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else {
            return nil
        }

        return containerURL
            .appendingPathComponent(sharedImportsDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func nextSharedImportURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }

        let importsURL = containerURL.appendingPathComponent(sharedImportsDirectoryName, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: importsURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let audioExtensions: Set<String> = ["aac", "aif", "aiff", "caf", "m4a", "mp3", "mp4", "wav"]
        // Newest-first: favor the memo the user just shared; stale orphans must not starve fresher imports.
        return urls
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
            }
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }
}

@MainActor
final class AppModel: ObservableObject {
    let store: SessionStore
    let home: HomeViewModel
    let recording: RecordingViewModel
    private var sharedAudioURLObserver: NSObjectProtocol?

    @Published var pendingSharedAudioURL: URL?

    init(store: SessionStore) {
        self.store = store
        self.home = HomeViewModel(store: store)
        self.recording = RecordingViewModel(store: store)
        self.sharedAudioURLObserver = NotificationCenter.default.addObserver(
            forName: .sharedAudioURLReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor [weak self] in
                self?.enqueueSharedAudioURL(url)
            }
        }
        let drainedURLs = SharedAudioURLInbox.shared.drain()
        if let url = drainedURLs.last {
            pendingSharedAudioURL = url
        }
        SharedAudioURLInbox.shared.enqueueNextSharedImportIfAvailable()
    }

    deinit {
        if let sharedAudioURLObserver {
            NotificationCenter.default.removeObserver(sharedAudioURLObserver)
        }
    }

    func enqueueSharedAudioURL(_ url: URL) {
        pendingSharedAudioURL = url
    }

    func enqueuePendingSharedImportIfAvailable() {
        guard pendingSharedAudioURL == nil else { return }
        guard !recording.isRecording, !recording.isFinishingWhisper, !recording.isTranscribingFile else { return }
        SharedAudioURLInbox.shared.enqueueNextSharedImportIfAvailable()
    }
}
