import Combine
import Foundation
import SpeechSessionFeatures
import SpeechSessionPersistence

extension Notification.Name {
    /// Posted when a queued App Group URL (audio or photo handoff, or opener URL) is ready to consume.
    static let sharedImportURLReceived = Notification.Name("SpeechSessionSharedImportURLReceived")
}

/// Drains queued files from `SharedAudioImports` and `SharedPhotoImports` in the App Group (newest first across both queues).
@MainActor
final class SharedImportURLInbox {
    static let shared = SharedImportURLInbox()

    private let appGroupID = "group.com.CollectiveCare.pilot"
    private let audioImportsDirectoryName = "SharedAudioImports"
    private let photoImportsDirectoryName = "SharedPhotoImports"

    /// Legacy opener URLs referenced only the audio folder; keep resolving there.
    private var legacySchemeImportsDirectoryName: String { audioImportsDirectoryName }

    private var pendingURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        if url.scheme == "collectivecare", url.host == "share-debug" {
            return
        }

        let resolvedURL = resolveHandoffURL(url) ?? url
        pendingURLs.append(resolvedURL)
        NotificationCenter.default.post(name: .sharedImportURLReceived, object: resolvedURL)
    }

    func drain() -> [URL] {
        defer { pendingURLs.removeAll() }
        return pendingURLs
    }

    func enqueueNextSharedImportIfAvailable() {
        guard let nextURL = nextCombinedQueueURL() else {
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
            .appendingPathComponent(legacySchemeImportsDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func nextCombinedQueueURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }

        let audioDir = containerURL.appendingPathComponent(audioImportsDirectoryName, isDirectory: true)
        let photoDir = containerURL.appendingPathComponent(photoImportsDirectoryName, isDirectory: true)

        var candidates: [(url: URL, date: Date)] = []
        candidates.append(contentsOf: collectQueuedFiles(directory: audioDir, extensions: SharedImportURLInbox.audioExtensions))
        candidates.append(contentsOf: collectQueuedFiles(directory: photoDir, extensions: SharedImportURLInbox.photoExtensions))

        return candidates.max(by: { $0.date < $1.date })?.url
    }

    private func collectQueuedFiles(directory: URL, extensions: Set<String>) -> [(url: URL, date: Date)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false }
            .filter {
                !$0.lastPathComponent.hasPrefix(".")
                    && !$0.path.contains("/InProgress/")
                    && !$0.path.contains("/Failed/")
            }
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { fileURL -> (URL, Date)? in
                let date = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return (fileURL, date)
            }
    }

    private static let audioExtensions: Set<String> = ["aac", "aif", "aiff", "caf", "m4a", "mp3", "mp4", "wav"]

    /// Extensions we write / accept for share-handoff images.
    private static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif"]
}

@MainActor
final class AppModel: ObservableObject {
    let store: SessionStore
    let home: HomeViewModel
    let recording: RecordingViewModel
    private var sharedImportURLObserver: NSObjectProtocol?

    /// Shared handoff queue (Voice Memos / Photos share extensions → App Group paths).
    @Published var pendingSharedImportURL: URL?

    init(store: SessionStore) {
        self.store = store
        self.home = HomeViewModel(store: store)
        self.recording = RecordingViewModel(store: store)
        self.sharedImportURLObserver = NotificationCenter.default.addObserver(
            forName: .sharedImportURLReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor [weak self] in
                self?.enqueueSharedImportURL(url)
            }
        }
        let drainedURLs = SharedImportURLInbox.shared.drain()
        if let url = drainedURLs.last {
            pendingSharedImportURL = url
        }
        SharedImportURLInbox.shared.enqueueNextSharedImportIfAvailable()
    }

    deinit {
        if let sharedImportURLObserver {
            NotificationCenter.default.removeObserver(sharedImportURLObserver)
        }
    }

    func enqueueSharedImportURL(_ url: URL) {
        pendingSharedImportURL = url
    }

    func enqueuePendingSharedImportIfAvailable() {
        guard pendingSharedImportURL == nil else { return }
        guard !recording.isRecording, !recording.isFinishingWhisper, !recording.isTranscribingFile else { return }
        SharedImportURLInbox.shared.enqueueNextSharedImportIfAvailable()
    }
}
