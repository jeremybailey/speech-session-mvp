import SwiftUI
import ActivityKit
import AVFoundation
import PhotosUI
import QuickLook
import VisionKit
import UniformTypeIdentifiers
import SpeechSessionAudio
import SpeechSessionFeatures
import SpeechSessionPersistence
import SpeechSessionTranscription

@MainActor
final class CaptureEditor: ObservableObject {
    @Published var record: Session
    @Published var recordingSince: Date?
    @Published var reminder: Bool
    @Published var starting = false
    @Published var error: String?
    var sources: SessionSourceStore?
    var closed = false
    private var request = UUID()
    private var saveSequence = 0
    private var write: Task<Void, Error>?
    static weak var active: CaptureEditor?
    private var activity: Activity<RecordingActivityAttributes>?
    private func showWidget() {
        RecordingLiveActivityBridge.clearPendingCommands()
        Self.active = self
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let anchor = Date().addingTimeInterval(-(record.capture?.duration ?? 0))
        activity = try? Activity.request(attributes: RecordingActivityAttributes(sessionTitle: "Recording"),
            content: ActivityContent(state: .init(phase: .recording, timerAnchor: anchor, frozenElapsedSeconds: 0), staleDate: nil), pushType: nil)
    }
    private func hideWidget() {
        if Self.active === self { Self.active = nil }
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
    private let microphone = AudioRecordingService()
    let store: SessionStore

    init(record: Session, store: SessionStore) {
        self.record = record
        self.store = store
        reminder = record.sourceAssets?.isEmpty != false && record.capture?.notes.isEmpty != false &&
            record.capture?.patientTitle.isEmpty != false
        microphone.onSessionEvent = { [weak self] event in
            Task { @MainActor in
                switch event {
                case .interruptionBegan, .mediaServicesReset, .routeChanged:
                    self?.pause()
                case .interruptionEnded: break
                }
            }
        }
    }

    var hasContent: Bool {
        record.sourceAssets?.isEmpty == false || record.capture?.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            record.capture?.patientTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func changed() {
        guard !closed else { return }
        saveSequence += 1
        let sequence = saveSequence
        let snapshot = record
        let prior = write
        write = Task { [store] in
            _ = await prior?.result
            guard sequence == self.saveSequence else { return }
            do { try await store.upsert(snapshot) }
            catch { self.error = "Your changes couldn’t be saved. Please try again."; throw error }
        }
    }

    func remove(_ asset: SessionSourceAsset) {
        record.sourceAssets?.removeAll { $0.id == asset.id }
        changed()
        let saved = write
        let url = sources?.url(for: asset, sessionID: record.id)
        Task {
            do {
                try await saved?.value
                // A newer edit may have coalesced the removal. Wait until it is on disk.
                try await write?.value
                if let url, let stored = try await store.loadAll().first(where: { $0.id == record.id }),
                   stored.sourceAssets?.contains(where: { $0.id == asset.id }) != true {
                    try FileManager.default.removeItem(at: url)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func typeOnly() {
        reminder = false
        starting = false
        request = UUID()
    }

    func start() async {
        guard !closed, !starting, recordingSince == nil, let sources else { return }
        reminder = false
        starting = true
        let token = UUID()
        request = token
        let allowed = await AudioRecordingService.requestRecordPermission()
        guard token == request, !closed else { return }
        starting = false
        guard allowed else {
            error = "Microphone access is off. You can write or attach a file, or enable the microphone in Settings."
            return
        }
        let number = (record.sourceAssets ?? []).filter { $0.kind == .audio }.count + 1
        let asset = SessionSourceAsset(kind: .audio, relativePath: UUID().uuidString + ".caf", displayName: "Recording \(number)")
        do {
            try microphone.startRecording(outputFileURL: sources.url(for: asset, sessionID: record.id)) { _ in }
            record.sourceAssets = (record.sourceAssets ?? []) + [asset]
            recordingSince = Date()
            showWidget()
            changed()
        } catch {
            microphone.stopRecording()
            self.error = error.localizedDescription
        }
    }

    func pause() {
        typeOnly()
        guard let since = recordingSince else { return }
        microphone.stopRecording()
        record.capture?.duration += Date().timeIntervalSince(since)
        hideWidget()
        recordingSince = nil
        changed()
    }

    func flush(commit: Bool, discard: Bool = false) async throws {
        pause()
        if !discard && hasContent {
            if commit {
                record.transcript = record.capture?.notes ?? ""
                record.capture?.isDraft = false
                record.capture?.pending = true
                record.title = record.capture?.patientTitle
            }
            changed()
        }
        closed = true
        do {
            try await write?.value
            if discard || !hasContent {
                if try await store.loadAll().contains(where: { $0.id == record.id }) { try await store.delete(id: record.id) }
            }
        } catch {
            closed = false
            record.capture?.isDraft = true
            record.capture?.pending = false
            throw error
        }
    }
}

struct StoryCaptureView: View {
    @StateObject private var editor: CaptureEditor
    @ObservedObject var home: HomeViewModel
    let finish: (UUID?) -> Void
    @EnvironmentObject private var health: HealthSummaryModel
    @Environment(\.storyRouter) private var router
    @State private var library = false
    @State private var camera = false
    @State private var scanner = false
    @State private var filePicker = false
    @State private var fileTypes: [UTType] = []
    @State private var photos: [PhotosPickerItem] = []
    @State private var preview: URL?
    @State private var extra: Extra?
    @State private var discard = false
    @State private var ending = false
    @State private var importing = false
    @Environment(\.scenePhase) private var phase
    private enum Extra: String, Identifiable {
        case detail, contact
        var id: String { rawValue }
    }

    init(record: Session, store: SessionStore, home: HomeViewModel, finish: @escaping (UUID?) -> Void) {
        _editor = StateObject(wrappedValue: CaptureEditor(record: record, store: store))
        self.home = home
        self.finish = finish
    }

    private func field(_ path: WritableKeyPath<RecordCapture, String>) -> Binding<String> {
        Binding(get: { editor.record.capture?[keyPath: path] ?? "" }, set: { text in
            editor.record.capture?[keyPath: path] = text
            editor.changed()
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Untitled record", text: field(\.patientTitle), axis: .vertical)
                        .font(StoryDesignTokens.sectionHeading)
                        .accessibilityIdentifier("Capture title")
                    Text(editor.record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(StoryDesignTokens.caption).foregroundStyle(.secondary)
                    TextField("Write notes here…", text: field(\.notes), axis: .vertical)
                        .font(StoryDesignTokens.body).lineLimit(6...)
                        .accessibilityIdentifier("Capture notes")
                    ForEach(editor.record.sourceAssets ?? []) { asset in
                        HStack {
                            Button {
                                preview = editor.sources?.url(for: asset, sessionID: editor.record.id)
                            } label: {
                                Label(asset.displayName, systemImage: asset.kind == .audio ? "waveform" : asset.kind == .image ? "photo" : "doc")
                            }
                            Spacer()
                            Button {
                                editor.remove(asset)
                            } label: { Image(systemName: "minus.circle") }
                            .disabled(asset.id == editor.record.sourceAssets?.last(where: { $0.kind == .audio })?.id && editor.recordingSince != nil)
                            .accessibilityLabel("Remove " + asset.displayName)
                        }.frame(minHeight: 44)
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(StoryDesignTokens.canvas)
            .safeAreaInset(edge: .bottom) { controls }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close(commit: false) } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close record and keep draft")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Photo library", systemImage: "photo.on.rectangle") { library = true }
                        Button("Camera", systemImage: "camera") { camera = true }
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        Button("Import document", systemImage: "doc") { fileTypes = [.pdf, .plainText]; filePicker = true }
                        Button("Scan pages", systemImage: "doc.viewfinder") { scanner = true }
                            .disabled(!VNDocumentCameraViewController.isSupported)
                        Button("Import audio", systemImage: "waveform") { fileTypes = [.audio]; filePicker = true }
                    } label: { Label("Attach", systemImage: "paperclip") }
                    .disabled(editor.sources == nil || importing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add health detail") { editor.pause(); extra = .detail }
                        Button("Add contact") { editor.pause(); extra = .contact }
                        Button("Discard draft", role: .destructive) { discard = true }
                    } label: { Label("More actions", systemImage: "ellipsis") }
                }
            }
        }
        .interactiveDismissDisabled(ending || importing)
        .disabled(ending)
        .task {
            router?.onCaptureDismiss = { [editor, home] in
                guard !editor.closed else { return }
                editor.pause()
                Task {
                    do { try await editor.flush(commit: false); await home.loadSessions() }
                    catch { home.errorMessage = error.localizedDescription }
                }
            }
            editor.sources = SessionSourceStore(storageDirectory: await editor.store.storageDirectory)
            guard editor.reminder else { return }
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: "Ask everyone’s permission before recording. Choose Record or Type only.")
                return
            }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, editor.reminder, phase == .active { await editor.start() }
        }
        .onChange(of: phase) { _, next in
            if next == .background && editor.reminder { editor.typeOnly() }
        }
        .quickLookPreview($preview)
        .photosPicker(isPresented: $library, selection: $photos, maxSelectionCount: 24, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                defer { importing = false; photos = [] }
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                        try attachImage(data, ext: item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")
                    } catch { editor.error = error.localizedDescription }
                }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraCaptureView { image in
                camera = false
                if let image { addImage(image) }
            }
        }
        .fullScreenCover(isPresented: $scanner) {
            DocumentScannerView { scan in
                scanner = false
                if let scan { for page in 0..<scan.pageCount { addImage(scan.imageOfPage(at: page)) } }
            }
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: fileTypes) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let sources = editor.sources else { return }
                let kind: SessionSourceKind = fileTypes == [.audio] ? .audio : url.pathExtension.lowercased() == "pdf" ? .pdf : .plainText
                let asset = try sources.copyFile(from: url, sessionID: editor.record.id, displayName: url.lastPathComponent, kind: kind)
                append(asset)
            } catch let e as CocoaError where e.code == .userCancelled {} catch { editor.error = error.localizedDescription }
        }
        .sheet(item: $extra) { action in
            switch action {
            case .detail: HealthManualEntryView(model: health, home: home, store: editor.store, topicID: nil)
            case .contact: CareTeamEditor(member: .init(), model: health)
            }
        }
        .confirmationDialog("Discard this draft and its attachments?", isPresented: $discard) {
            Button("Discard draft", role: .destructive) { close(commit: false, discard: true) }
        }
        .alert("Record", isPresented: Binding(get: { editor.error != nil }, set: { if !$0 { editor.error = nil } })) {
            Button("OK") {}
        } message: { Text(editor.error ?? "") }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            if editor.reminder {
                Text("Ask everyone’s permission before recording.").font(StoryDesignTokens.label)
                HStack {
                    Button("Type only") { editor.typeOnly() }
                    if UIAccessibility.isVoiceOverRunning { Button("Record") { Task { await editor.start() } } }
                }
            } else {
                HStack {
                    if editor.starting {
                        Button("Type only") { editor.typeOnly() }
                    } else if editor.recordingSince != nil {
                        Button("Pause", systemImage: "pause.fill") { editor.pause() }
                    } else {
                        Button((editor.record.capture?.duration ?? 0) > 0 ? "Resume" : "Record", systemImage: "mic.fill") {
                            Task { await editor.start() }
                        }
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        let seconds = Int((editor.record.capture?.duration ?? 0) + (editor.recordingSince.map { max(0, tick.date.timeIntervalSince($0)) } ?? 0))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                    }
                    Spacer()
                    Button("Done") { close(commit: true) }.buttonStyle(.borderedProminent)
                        .disabled(!editor.hasContent || importing)
                }
            }
        }.padding().background(.regularMaterial)
    }

    private func close(commit: Bool, discard: Bool = false) {
        guard !ending, !importing else { return }
        ending = true
        Task {
            do {
                try await editor.flush(commit: commit, discard: discard)
                await home.loadSessions()
                finish(commit ? editor.record.id : nil)
            } catch { ending = false; editor.error = error.localizedDescription }
        }
    }

    private func addImage(_ image: UIImage) {
        do {
            guard let data = image.jpegData(compressionQuality: 0.94) else { throw CocoaError(.fileReadCorruptFile) }
            try attachImage(data, ext: "jpg")
        } catch { editor.error = error.localizedDescription }
    }

    private func attachImage(_ data: Data, ext: String) throws {
        guard let sources = editor.sources else { throw CocoaError(.fileWriteUnknown) }
        let count = (editor.record.sourceAssets ?? []).filter { $0.kind == .image }.count + 1
        let asset = try sources.saveData(data, sessionID: editor.record.id, fileName: UUID().uuidString + "." + ext,
                                         displayName: "Photo \(count)", kind: .image)
        append(asset)
    }

    private func append(_ asset: SessionSourceAsset) {
        editor.record.sourceAssets = (editor.record.sourceAssets ?? []) + [asset]
        editor.changed()
    }
}

/// Extraction continues when a patient leaves the record. Each original has its own durable checkpoint.
@MainActor
final class CaptureProcessing: ObservableObject {
    static let shared = CaptureProcessing()
    @Published private(set) var active: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]

    func start(_ record: Session, store: SessionStore, home: HomeViewModel, health: HealthSummaryModel, auth: KindeAuthManager) {
        guard let capture = record.capture, !capture.isDraft, active.insert(record.id).inserted else { return }
        errors[record.id] = nil
        Task {
            defer { active.remove(record.id) }
            do {
                guard let latest = try await store.loadAll().first(where: { $0.id == record.id }),
                      let current = latest.capture, !current.isDraft else { return }
                let sources = SessionSourceStore(storageDirectory: await store.storageDirectory)
                for asset in latest.sourceAssets ?? [] where current.textByAsset[asset.id] == nil || current.failedAssets.contains(asset.id) {
                    let url = sources.url(for: asset, sessionID: latest.id)
                    let text: String?
                    do {
                        switch asset.kind {
                        case .pdf, .plainText:
                            text = try await DocumentFileExtractService().extractText(from: url)
                        case .image, .multiPageScan:
                            guard let image = UIImage(contentsOfFile: url.path) else { throw CocoaError(.fileReadCorruptFile) }
                            text = try await DocumentScanService().transcribe(images: [image])
                        case .audio:
                            text = try await transcribe(url, auth: auth)
                        }
                    } catch {
                        try await store.checkpointCapture(id: latest.id, asset: asset.id, text: nil, publish: false)
                        continue
                    }
                    let readable = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await store.checkpointCapture(id: latest.id, asset: asset.id, text: readable?.isEmpty == false ? text : nil, publish: false)
                }
                try await store.checkpointCapture(id: latest.id, asset: nil, text: nil, publish: true)
                await home.loadSessions()
                await health.refresh()
                let defaults = UserDefaults.standard
                let local = defaults.string(forKey: "speechSession.summaryBackend") == "onDevice"
                if local || defaults.bool(forKey: "collectivecare.cloudSummaryConsent") {
                    let transport = local ? nil : await auth.openAIChatTransport(byokFallback: defaults.string(forKey: "speechSession.openaiAPIKey") ?? "")
                    await health.updateHealthStory(transport: transport, onDevice: local, explicitlyRequested: true)
                    await home.loadSessions()
                }
            } catch { errors[record.id] = error.localizedDescription }
        }
    }

    private func transcribe(_ url: URL, auth: KindeAuthManager) async throws -> String {
        let defaults = UserDefaults.standard
        switch TranscriptionBackend(rawValue: defaults.string(forKey: "speechSession.transcriptionBackend") ?? "") ?? .onDeviceWhisperKit {
        case .onDeviceApple:
            return try await AudioFileTranscriptionService.transcribeWithAppleSpeech(fileURL: url)
        case .onDeviceWhisperKit:
            return try await AudioFileTranscriptionService.transcribeWithWhisperKit(fileURL: url, modelName: defaults.string(forKey: "speechSession.whisperKitModel") ?? DeviceCapabilityProfile.tinyWhisperKitModel)
        case .openAIWhisper:
            guard let credentials = await auth.openAIWhisperCredentials(byokKey: defaults.string(forKey: "speechSession.openaiAPIKey") ?? "") else {
                throw SummaryProcessingError.unavailable("Sign in to transcribe this recording.")
            }
            return try await AudioFileTranscriptionService.transcribeWithOpenAIWhisper(fileURL: url, credentials: credentials)
        }
    }
}
