import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit
import PhotosUI
import SpeechSessionFeatures
import SpeechSessionPersistence

struct HomeView: View {
    /// Which menu action opened the Files sheet (drives `allowedContentTypes` for the single `fileImporter`).
    private enum FileImportKind: Equatable {
        case audio
        case pdfOrPlainText
    }

    @ObservedObject var home: HomeViewModel
    @ObservedObject var recording: RecordingViewModel
    let store: SessionStore
    var listScope: EntryListScope = .all
    @Binding var pendingSharedImportURL: URL?
    /// Called after consuming (or rejecting) one App Group handoff so queued files + folder scan can drain.
    var advanceSharedImportQueue: () -> Void = {}

    @EnvironmentObject private var health: HealthSummaryModel
    @EnvironmentObject private var kindeAuth: KindeAuthManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("speechSession.transcriptionBackend") private var backendRaw = TranscriptionBackend.onDeviceWhisperKit.rawValue
    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.whisperKitModel") private var whisperKitModel = DeviceCapabilityProfile.tinyWhisperKitModel
    @AppStorage("speechSession.whisperKitExperimentalUnlock") private var whisperKitExperimentalUnlock = false

    @State private var showSettings = false
    @State private var pulseAnimation = false
    @State private var showDocumentScanner = false
    @State private var showCameraCapture = false
    /// Populated immediately before presenting the unified file importer (`showFileImporter`).
    @State private var pendingFileImportKind: FileImportKind?
    @State private var showFileImporter = false
    /// Intent captured before presenting the audio file importer.
    @State private var pendingImportAudioEntryIntent: SessionEntryIntent?
    @State private var showAddEntrySheet = false
    @State private var showManualDetail = false
    @State private var showContact = false
    @State private var showPhotosPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var isScanningDocument = false
    @State private var scanErrorMessage: String? = nil
    @State private var fileErrorMessage: String? = nil
    @State private var showRecordingError = false
    /// Prevents overlapping App Group consumes when audio and photo handlers race.
    @State private var isConsumingPendingSharedImport = false

    private var selectedBackend: TranscriptionBackend {
        TranscriptionBackend(rawValue: backendRaw) ?? .onDeviceWhisperKit
    }

    private var fileImporterAllowedTypes: [UTType] {
        switch pendingFileImportKind {
        case .audio:
            return [.audio]
        case .pdfOrPlainText:
            return [.pdf, .plainText, .utf8PlainText]
        case nil:
            return [.item]
        }
    }

    // Derive recording phase purely from the ViewModel — no duplicate state.
    private enum RecordingPhase { case idle, recording, transcribing, scanTranscribing, fileTranscribing }
    private var phase: RecordingPhase {
        if isScanningDocument { return .scanTranscribing }
        if recording.isTranscribingFile { return .fileTranscribing }
        if recording.isFinishingWhisper { return .transcribing }
        if recording.isRecording { return .recording }
        return .idle
    }

    var body: some View {
        HealthSummaryView(model: health, home: home, store: store, canOpenSettings: phase == .idle, openSettings: { showSettings = true })
        .background(BrandPalette.canvas)
        .navigationTitle("My health story")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showAddEntrySheet) {
            AddEntryFlowSheet(
                isPresented: $showAddEntrySheet,
                onAudioRecord: { intent in
                    startLiveRecording(intent: intent)
                },
                onAudioImport: { intent in
                    prepareAudioFileImport(intent: intent)
                },
                onPhotoCapture: {
                    scanErrorMessage = nil
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        scanErrorMessage =
                            "Camera isn’t available on this device. Use an iPhone or iPad with a camera, or choose photos from your library."
                        return
                    }
                    showCameraCapture = true
                },
                onPhotoLibrary: {
                    scanErrorMessage = nil
                    showPhotosPicker = true
                },
                onDocumentScan: {
                    scanErrorMessage = nil
                    showDocumentScanner = true
                },
                onDocumentImport: {
                    scanErrorMessage = nil
                    pendingFileImportKind = .pdfOrPlainText
                    showFileImporter = true
                },
                onWriteDetail: { showManualDetail = true },
                onAddContact: { showContact = true }
            )
        }
        .sheet(isPresented: $showManualDetail) {
            HealthManualEntryView(model: health, home: home, store: store, topicID: nil)
        }
        .sheet(isPresented: $showContact) { CareTeamEditor(member: .init(), model: health) }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photoPickerItems, maxSelectionCount: 24, matching: .images, photoLibrary: .shared())
        .onChange(of: photoPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            isScanningDocument = true
            scanErrorMessage = nil
            Task { await processPhotoPickerItems(newItems) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(isPresented: $showSettings)
        }
        .fullScreenCover(isPresented: $showCameraCapture) {
            CameraCaptureView { image in
                showCameraCapture = false
                guard let image else { return }
                isScanningDocument = true
                scanErrorMessage = nil
                Task { await processPickedImagesForOCR([image]) }
            }
        }
        .fullScreenCover(isPresented: $showDocumentScanner) {
            DocumentScannerView { scan in
                showDocumentScanner = false
                guard let scan else { return }
                isScanningDocument = true
                scanErrorMessage = nil
                Task { await processDocumentScan(scan) }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: fileImporterAllowedTypes,
            allowsMultipleSelection: false
        ) { result in
            Task { @MainActor in
                let kind = pendingFileImportKind
                let audioEntryIntent = pendingImportAudioEntryIntent
                pendingFileImportKind = nil
                pendingImportAudioEntryIntent = nil
                guard let kind else { return }
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    switch kind {
                    case .audio:
                        await processAudioFile(url, entryIntent: audioEntryIntent ?? .clinicalVisit)
                    case .pdfOrPlainText:
                        await processImportedDocumentFile(url)
                    }
                case .failure(let error):
                    switch kind {
                    case .audio:
                        fileErrorMessage = error.localizedDescription
                    case .pdfOrPlainText:
                        scanErrorMessage = error.localizedDescription
                    }
                }
            }
        }
        // Floating controls reserve scroll clearance without an opaque full-width bottom plate.
        .safeAreaInset(edge: .bottom) {
            bottomAccessoryBar
                .frame(maxWidth: .infinity)

        }
        .task {
            await home.loadSessions()
            await consumePendingSharedImportIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveActivityStartRecording)) { _ in
            guard !recording.isRecording, !recording.isFinishingWhisper, !recording.isTranscribingFile else { return }
            startLiveRecording(intent: .clinicalVisit)
        }
        .task(id: "\(backendRaw)|\(whisperKitModel)|\(whisperKitExperimentalUnlock)") {
            normalizeTranscriptionStorageForDevice()
            await prefetchWhisperKitModelIfNeeded()
        }
        .onChange(of: pendingSharedImportURL) { _, _ in
            Task { await consumePendingSharedImportIfNeeded() }
        }
        .onChange(of: recording.errorMessage) { _, newValue in
            showRecordingError = newValue != nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            recording.setAppInBackground(newPhase != .active)
        }
    }

    // MARK: - Bottom + button & active-state pills

    @ViewBuilder
    private var bottomAccessoryBar: some View {
        VStack(spacing: 10) {
            if phase == .idle {
                idleErrorBanners
                addEntryFloatingButton
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            } else {
                if phase == .recording, let status = recording.recordingStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                activePhasePill
                    .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var idleErrorBanners: some View {
        VStack(spacing: 6) {
            if showRecordingError, let error = recording.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(BrandPalette.systemRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let error = scanErrorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(BrandPalette.systemRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let error = fileErrorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(BrandPalette.systemRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    /// Native glass capsule floats above the list and remains clear of the home indicator.
    private var addEntryFloatingButton: some View {
        Button {
            scanErrorMessage = nil
            fileErrorMessage = nil
            showAddEntrySheet = true
        } label: {
            Label("Add record", systemImage: "plus")
                .font(.headline)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
        .summarySecondaryButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(BrandPalette.systemBlue)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var activePhasePill: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .recording:
            recordingPill
        case .transcribing:
            transcribingPill
        case .scanTranscribing:
            scanTranscribingPill
        case .fileTranscribing:
            fileTranscribingPill
        }
    }

    // Scanning document pill — OCR in progress
    private var scanTranscribingPill: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.85)
            Text("Extracting text…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .frame(height: 56)
        .liquidGlassCapsule()
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // Expanded pill — timer + stop button
    private var recordingPill: some View {
        Button {
            Task {
                _ = await recording.stop()
                await home.loadSessions()
            }
        } label: {
            HStack(spacing: 14) {
                // Pulsing red dot
                Circle()
                    .fill(BrandPalette.systemRed)
                    .frame(width: 9, height: 9)
                    .scaleEffect(pulseAnimation ? 1.4 : 1.0)
                    .opacity(pulseAnimation ? 0.5 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                        value: pulseAnimation
                    )
                    .onAppear { pulseAnimation = true }
                    .onDisappear { pulseAnimation = false }

                Text(formattedElapsed(recording.elapsed))
                    .font(.title3.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())

                Divider()
                    .frame(height: 20)

                Label("Stop recording", systemImage: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BrandPalette.systemRed)
            }
            .padding(.horizontal, 28)
            .frame(height: 56)
            .liquidGlassCapsule()
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // Transcribing pill — spinner
    private var transcribingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.85)
            Text("Transcribing…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .frame(height: 56)
        .liquidGlassCapsule()
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // Imported audio file pill — transcription in progress
    private var fileTranscribingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.85)
            Text("Transcribing file…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .frame(height: 56)
        .liquidGlassCapsule()
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func formattedElapsed(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func startLiveRecording(intent: SessionEntryIntent) {
        Task {
            let creds = await kindeAuth.openAIWhisperCredentials(byokKey: openAIAPIKey)
            recording.prepareForRecording(
                backend: selectedBackend,
                openAIAPIKey: openAIAPIKey,
                openAIWhisperCredentials: creds,
                whisperKitModel: whisperKitModel,
                experimentalWhisperKitUnlocked: whisperKitExperimentalUnlock,
                entryIntent: intent,
                defaultFolderID: listScope.defaultFolderID
            )
            await recording.start()
        }
    }

    private func prepareAudioFileImport(intent: SessionEntryIntent) {
        pendingImportAudioEntryIntent = intent
        fileErrorMessage = nil
        pendingFileImportKind = .audio
        showFileImporter = true
    }

    // MARK: - WhisperKit defaults / prefetch

    private func normalizeTranscriptionStorageForDevice() {
        guard selectedBackend == .onDeviceWhisperKit else { return }
        let profile = DeviceCapabilityProfile.current
        if !profile.permitsWhisperKitModel(whisperKitModel, experimentalUnlocked: whisperKitExperimentalUnlock),
           let fallback = profile.allowedWhisperKitModels(experimentalUnlocked: whisperKitExperimentalUnlock).first {
            whisperKitModel = fallback
        }
    }

    private func prefetchWhisperKitModelIfNeeded() async {
        guard selectedBackend == .onDeviceWhisperKit else { return }
        let profile = DeviceCapabilityProfile.current
        guard profile.permitsWhisperKitModel(whisperKitModel, experimentalUnlocked: whisperKitExperimentalUnlock) else { return }
        guard await !WhisperKitModelSetup.isModelCached(whisperKitModel) else { return }
        try? await WhisperKitModelSetup.downloadModel(whisperKitModel)
    }

    private func makeSourceStore() async -> SessionSourceStore {
        let directory = await store.storageDirectory
        return SessionSourceStore(storageDirectory: directory)
    }

    private func saveOriginalThenRead(id: UUID, inputType: SessionInputType, assets: [SessionSourceAsset], read: () async throws -> String) async throws {
        var draft = Session(id: id, transcript: "", title: assets.first?.displayName ?? "Health document",
                            inputType: inputType, folderID: listScope.defaultFolderID, sourceAssets: assets)
        draft.processingState = .transcribing
        try await store.upsert(draft)
        await home.loadSessions()
        do {
            let text = try await read()
            let warning = text.contains("[Text unavailable") ? "Some pages could not be read. Check the original before relying on this summary." : nil
            try await store.updateTranscript(sessionID: id, transcript: text, error: warning)
        } catch {
            try await store.updateTranscript(sessionID: id, transcript: nil, error: "The original is saved. " + error.localizedDescription)
            scanErrorMessage = "The original is saved. You can try reading it again under Original records."
        }
        await home.loadSessions()
    }

    private func jpegData(from image: UIImage) -> Data? {
        image.jpegData(compressionQuality: 0.85)
    }

    private func sourceAssetsForImages(_ images: [UIImage], sessionID: UUID, sourceStore: SessionSourceStore) throws -> [SessionSourceAsset] {
        let pages = images.enumerated().compactMap { index, image -> (data: Data, displayName: String)? in
            guard let data = jpegData(from: image) else { return nil }
            let title = images.count > 1 ? "Page \(index + 1)" : "Photo"
            return (data, title)
        }
        guard !pages.isEmpty else { return [] }
        if pages.count == 1 {
            let asset = try sourceStore.saveData(
                pages[0].data,
                sessionID: sessionID,
                fileName: "photo.jpg",
                displayName: pages[0].displayName,
                kind: .image
            )
            return [asset]
        }
        return try sourceStore.saveScanPages(pages, sessionID: sessionID)
    }

    // MARK: - Document / photo OCR

    private func processDocumentScan(_ scan: VNDocumentCameraScan) async {
        defer { isScanningDocument = false }
        do {
            var images: [UIImage] = []
            images.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            let sessionID = UUID()
            let sourceStore = await makeSourceStore()
            let assets = try sourceAssetsForImages(images, sessionID: sessionID, sourceStore: sourceStore)
            try await saveOriginalThenRead(id: sessionID, inputType: .documentScan, assets: assets) {
                try await DocumentScanService().transcribe(images: images)
            }
        } catch {
            scanErrorMessage = error.localizedDescription
        }
    }

    /// Loads picker items and OCRs images with the same pipeline as plain camera captures and document scans.
    private func processPhotoPickerItems(_ items: [PhotosPickerItem]) async {
        await MainActor.run { photoPickerItems.removeAll(keepingCapacity: false) }

        var images: [UIImage] = []
        images.reserveCapacity(items.count)

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                images.append(uiImage)
            }
        }

        await processPickedImagesForOCR(images)
    }

    private func processPickedImagesForOCR(_ images: [UIImage]) async {
        defer { isScanningDocument = false }
        guard !images.isEmpty else {
            scanErrorMessage = DocumentScanError.noImages.errorDescription
            return
        }
        do {
            let sessionID = UUID()
            let sourceStore = await makeSourceStore()
            let assets = try sourceAssetsForImages(images, sessionID: sessionID, sourceStore: sourceStore)
            try await saveOriginalThenRead(id: sessionID, inputType: .documentImage, assets: assets) {
                try await DocumentScanService().transcribe(images: images)
            }
        } catch {
            scanErrorMessage = error.localizedDescription
        }
    }

    /// Plain-text files and PDFs from the Files sheet (same document entry path as OCR).
    private func processImportedDocumentFile(_ url: URL) async {
        isScanningDocument = true
        scanErrorMessage = nil
        defer { isScanningDocument = false }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let sessionID = UUID()
            let sourceStore = await makeSourceStore()
            let ext = url.pathExtension.lowercased()
            let kind: SessionSourceKind = ext == "pdf" ? .pdf : .plainText
            let asset = try sourceStore.copyFile(
                from: url,
                sessionID: sessionID,
                displayName: url.lastPathComponent,
                kind: kind
            )
            try await saveOriginalThenRead(id: sessionID, inputType: .documentFile, assets: [asset]) {
                try await DocumentFileExtractService().extractText(from: sourceStore.url(for: asset, sessionID: sessionID))
            }
        } catch {
            scanErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Shared handoff (App Group audio + photo share extensions)

    private func consumePendingSharedImportIfNeeded() async {
        guard !isConsumingPendingSharedImport else { return }
        guard let sourceURL = pendingSharedImportURL else { return }

        isConsumingPendingSharedImport = true
        defer {
            isConsumingPendingSharedImport = false
            Task { @MainActor in
                advanceSharedImportQueue()
                await consumePendingSharedImportIfNeeded()
            }
        }
        pendingSharedImportURL = nil

        guard sourceURL.isFileURL else {
            fileErrorMessage = "Shared item is not a local file."
            return
        }

        if isSharedPhotoHandoffQueuedFile(sourceURL) {
            scanErrorMessage = nil
            await consumeSharedPhotoHandoff(sourceURL)
        } else if isSharedDocumentHandoffQueuedFile(sourceURL) {
            scanErrorMessage = nil
            await consumeSharedDocumentHandoff(sourceURL)
        } else {
            guard isSupportedAudioURL(sourceURL) else {
                fileErrorMessage = "Shared item is not a supported audio file."
                return
            }
            fileErrorMessage = nil
            await processAudioFile(sourceURL, entryIntent: .clinicalVisit)
        }
    }

    private func isSharedPhotoHandoffQueuedFile(_ url: URL) -> Bool {
        let path = url.path
        guard path.contains("/SharedPhotoImports/") else { return false }
        return !path.contains("/SharedPhotoImports/InProgress/")
            && !path.contains("/SharedPhotoImports/Failed/")
    }

    private func isSharedDocumentHandoffQueuedFile(_ url: URL) -> Bool {
        let path = url.path
        guard path.contains("/SharedDocumentImports/") else { return false }
        return !path.contains("/SharedDocumentImports/InProgress/")
            && !path.contains("/SharedDocumentImports/Failed/")
    }

    private func consumeSharedPhotoHandoff(_ url: URL) async {
        isScanningDocument = true
        defer { isScanningDocument = false }

        let claimedURL: URL
        do {
            claimedURL = try claimAppGroupSharedImportIfNeeded(url)
        } catch {
            scanErrorMessage = error.localizedDescription
            return
        }

        do {
            let data = try Data(contentsOf: claimedURL)
            guard let uiImage = UIImage(data: data) else {
                scanErrorMessage = "Could not read the photo data."
                revertSharedImportClaimIfNeeded(claimedURL)
                return
            }
            let sessionID = UUID()
            let sourceStore = await makeSourceStore()
            let assets = try sourceAssetsForImages([uiImage], sessionID: sessionID, sourceStore: sourceStore)
            try await saveOriginalThenRead(id: sessionID, inputType: .documentImage, assets: assets) {
                try await DocumentScanService().transcribe(images: [uiImage])
            }
            removeSharedImportIfNeeded(claimedURL)
        } catch {
            scanErrorMessage = error.localizedDescription
            revertSharedImportClaimIfNeeded(claimedURL)
        }
    }

    private func consumeSharedDocumentHandoff(_ url: URL) async {
        isScanningDocument = true
        scanErrorMessage = nil
        defer { isScanningDocument = false }

        let claimedURL: URL
        do {
            claimedURL = try claimAppGroupSharedImportIfNeeded(url)
        } catch {
            scanErrorMessage = error.localizedDescription
            return
        }

        do {
            let sessionID = UUID()
            let sourceStore = await makeSourceStore()
            let ext = claimedURL.pathExtension.lowercased()
            let kind: SessionSourceKind = ext == "pdf" ? .pdf : .plainText
            let asset = try sourceStore.copyFile(
                from: claimedURL,
                sessionID: sessionID,
                displayName: claimedURL.lastPathComponent,
                kind: kind
            )
            try await saveOriginalThenRead(id: sessionID, inputType: .documentFile, assets: [asset]) {
                try await DocumentFileExtractService().extractText(from: sourceStore.url(for: asset, sessionID: sessionID))
            }
            removeSharedImportIfNeeded(claimedURL)
        } catch {
            scanErrorMessage = error.localizedDescription
            revertSharedImportClaimIfNeeded(claimedURL)
        }
    }

    // MARK: - Audio file processing

    private func processAudioFile(_ sourceURL: URL, entryIntent: SessionEntryIntent = .clinicalVisit) async {
        let claimedURL: URL
        do {
            claimedURL = try claimAppGroupSharedImportIfNeeded(sourceURL)
        } catch {
            fileErrorMessage = error.localizedDescription
            return
        }

        do {
            let tempURL = try copyImportedAudioToTemporaryFile(claimedURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let isShareHandoffImport = claimedURL.path.contains("/SharedAudioImports/")

            let whisperCreds = await kindeAuth.openAIWhisperCredentials(byokKey: openAIAPIKey)

            var session = await recording.transcribeAudioFile(
                tempURL,
                backend: selectedBackend,
                openAIAPIKey: openAIAPIKey,
                openAIWhisperCredentials: whisperCreds,
                whisperKitModel: whisperKitModel,
                experimentalWhisperKitUnlocked: whisperKitExperimentalUnlock,
                entryIntent: entryIntent,
                defaultFolderID: listScope.defaultFolderID
            )

            if session == nil,
               isShareHandoffImport,
               selectedBackend == .onDeviceApple
            {
                let profile = DeviceCapabilityProfile.current
                let modelName = whisperKitModel
                let canWK = profile.permitsWhisperKit(experimentalUnlocked: whisperKitExperimentalUnlock)
                    && profile.permitsWhisperKitModel(modelName, experimentalUnlocked: whisperKitExperimentalUnlock)
                if canWK {
                    session = await recording.transcribeAudioFile(
                        tempURL,
                        backend: .onDeviceWhisperKit,
                        openAIAPIKey: openAIAPIKey,
                        openAIWhisperCredentials: whisperCreds,
                        whisperKitModel: modelName,
                        experimentalWhisperKitUnlocked: whisperKitExperimentalUnlock,
                        entryIntent: entryIntent,
                        defaultFolderID: listScope.defaultFolderID
                    )
                }
            }
            if session != nil {
                removeSharedImportIfNeeded(claimedURL)
                await home.loadSessions()
            } else {
                revertSharedImportClaimIfNeeded(claimedURL)
            }
        } catch {
            fileErrorMessage = error.localizedDescription
            revertSharedImportClaimIfNeeded(claimedURL)
        }
    }

    /// Moves a queued App Group file into `InProgress` so foreground rescans cannot enqueue it twice.
    private func claimAppGroupSharedImportIfNeeded(_ url: URL) throws -> URL {
        guard url.isFileURL else { return url }
        let path = url.path
        let isQueuedAudioShare = path.contains("/SharedAudioImports/")
            && !path.contains("/SharedAudioImports/InProgress/")
            && !path.contains("/SharedAudioImports/Failed/")
        let isQueuedPhotoShare = path.contains("/SharedPhotoImports/")
            && !path.contains("/SharedPhotoImports/InProgress/")
            && !path.contains("/SharedPhotoImports/Failed/")
        let isQueuedDocumentShare = path.contains("/SharedDocumentImports/")
            && !path.contains("/SharedDocumentImports/InProgress/")
            && !path.contains("/SharedDocumentImports/Failed/")

        guard isQueuedAudioShare || isQueuedPhotoShare || isQueuedDocumentShare else {
            return url
        }

        let fm = FileManager.default
        let parentDir = url.deletingLastPathComponent()
        let inProgressDir = parentDir.appendingPathComponent("InProgress", isDirectory: true)
        try fm.createDirectory(at: inProgressDir, withIntermediateDirectories: true)
        let destination = inProgressDir.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: url, to: destination)
        return destination
    }

    private func revertSharedImportClaimIfNeeded(_ claimedURL: URL) {
        guard claimedURL.path.contains("/InProgress/") else { return }
        let path = claimedURL.path
        guard path.contains("/SharedAudioImports/")
            || path.contains("/SharedPhotoImports/")
            || path.contains("/SharedDocumentImports/") else { return }

        let fm = FileManager.default
        let importsRoot = claimedURL.deletingLastPathComponent().deletingLastPathComponent()
        let failedDir = importsRoot.appendingPathComponent("Failed", isDirectory: true)
        try? fm.createDirectory(at: failedDir, withIntermediateDirectories: true)
        let dest = failedDir.appendingPathComponent(
            UUID().uuidString + "_" + claimedURL.lastPathComponent,
            isDirectory: false
        )
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        try? fm.moveItem(at: claimedURL, to: dest)
    }

    private func copyImportedAudioToTemporaryFile(_ sourceURL: URL) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        return tempURL
    }

    private func removeSharedImportIfNeeded(_ sourceURL: URL) {
        guard sourceURL.path.contains("/SharedAudioImports/")
            || sourceURL.path.contains("/SharedPhotoImports/")
            || sourceURL.path.contains("/SharedDocumentImports/") else { return }
        try? FileManager.default.removeItem(at: sourceURL)
    }

    private func isSupportedAudioURL(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        let commonAudioExtensions: Set<String> = ["aac", "aif", "aiff", "caf", "m4a", "mp3", "mp4", "wav"]
        if commonAudioExtensions.contains(fileExtension) {
            return true
        }
        return UTType(filenameExtension: fileExtension)?.conforms(to: .audio) == true
    }
}

private extension Text {
    func italic(_ condition: Bool) -> Text {
        condition ? self.italic() : self
    }
}
