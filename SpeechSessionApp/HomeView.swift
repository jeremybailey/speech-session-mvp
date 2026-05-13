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

    @EnvironmentObject private var kindeAuth: KindeAuthManager

    @AppStorage("speechSession.transcriptionBackend") private var backendRaw = TranscriptionBackend.onDeviceWhisperKit.rawValue
    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.whisperKitModel") private var whisperKitModel = DeviceCapabilityProfile.tinyWhisperKitModel
    @AppStorage("speechSession.whisperKitExperimentalUnlock") private var whisperKitExperimentalUnlock = false

    @State private var showSettings = false
    /// Sheet (not navigation push) avoids nested-`NavigationStack` presentation bugs on iPad that swallow all touches.
    @State private var showHealthSummarySheet = false
    @State private var pulseAnimation = false
    @State private var showDocumentScanner = false
    @State private var showCameraCapture = false
    /// Populated immediately before presenting the unified file importer (`showFileImporter`).
    @State private var pendingFileImportKind: FileImportKind?
    @State private var showFileImporter = false
    /// Intent captured before presenting the audio file importer.
    @State private var pendingImportAudioEntryIntent: SessionEntryIntent?
    @State private var showAddEntrySheet = false
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
    private var displayedSessions: [Session] {
        switch listScope {
        case .all:
            return home.sessions
        case .folder(let id):
            return home.sessions.filter { $0.folderID == id }
        }
    }

    private var listTitle: String {
        switch listScope {
        case .all:
            return "All entries"
        case .folder(let id):
            return home.folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    private var phase: RecordingPhase {
        if isScanningDocument { return .scanTranscribing }
        if recording.isTranscribingFile { return .fileTranscribing }
        if recording.isFinishingWhisper { return .transcribing }
        if recording.isRecording { return .recording }
        return .idle
    }

    private var summaryPinnedSubtitle: String {
        switch listScope {
        case .all:
            let n = home.sessions.count
            return n == 0 ? "All entries" : "Across \(n) entr\(n == 1 ? "y" : "ies")"
        case .folder(let id):
            let name = home.folders.first { $0.id == id }?.name ?? "Folder"
            let n = displayedSessions.count
            return n == 0 ? name : "\(name) · \(n) entr\(n == 1 ? "y" : "ies")"
        }
    }

    /// Uppercase secondary header, aligned with `List` / inset content (system section-header pattern).
    private var entriesSectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Entries")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                showHealthSummarySheet = true
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.pink)
                        .frame(width: 36, height: 36)
                        .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Health summary")
                            .font(.headline)
                        Text(summaryPinnedSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .summaryGlassCard(cornerRadius: 16)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // List section header — matches system grouped `Section` header styling (Health, Settings).
            entriesSectionHeader

            List {
                if displayedSessions.isEmpty && phase == .idle {
                    switch listScope {
                    case .all:
                        emptyStateRow
                    case .folder:
                        folderEmptyStateRow
                    }
                } else {
                    ForEach(displayedSessions) { session in
                        NavigationLink(value: session) {
                            sessionRow(session)
                        }
                        .listRowBackground(BrandPalette.canvas)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let session = displayedSessions[index]
                            Task { await home.delete(session: session) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .background(BrandPalette.canvas)
        .animation(.default, value: displayedSessions.map(\.id))
        .navigationTitle(listTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .disabled(phase != .idle)
            }
        }
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
                }
            )
        }
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
        .sheet(isPresented: $showHealthSummarySheet) {
            NavigationStack {
                ScopedHealthSummaryView(scope: listScope, home: home, store: store)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showHealthSummarySheet = false }
                        }
                    }
            }
            .background(BrandPalette.canvas.ignoresSafeArea())
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
        // Bottom + button (idle) or recording / transcription pills; contentShape keeps list from stealing taps.
        .safeAreaInset(edge: .bottom) {
            bottomAccessoryBar
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .task {
            await home.loadSessions()
            await consumePendingSharedImportIfNeeded()
        }
        .task(id: "\(backendRaw)|\(whisperKitModel)|\(whisperKitExperimentalUnlock)") {
            normalizeTranscriptionStorageForDevice()
            await prefetchWhisperKitModelIfNeeded()
        }
        .onChange(of: pendingSharedImportURL) { _, _ in
            Task { await consumePendingSharedImportIfNeeded() }
        }
        // Auto-dismiss error messages after 4 seconds.
        .onChange(of: recording.errorMessage) { _, newValue in
            guard newValue != nil else { return }
            showRecordingError = true
            Task {
                try? await Task.sleep(for: .seconds(4))
                showRecordingError = false
            }
        }
        .onChange(of: scanErrorMessage) { _, newValue in
            guard newValue != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(4))
                scanErrorMessage = nil
            }
        }
        .onChange(of: fileErrorMessage) { _, newValue in
            guard newValue != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(4))
                fileErrorMessage = nil
            }
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
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let error = scanErrorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let error = fileErrorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    /// Voice Memos–style primary control; 70×70 pt exceeds the 44 pt minimum for older adults.
    private var addEntryFloatingButton: some View {
        Button {
            scanErrorMessage = nil
            fileErrorMessage = nil
            showAddEntrySheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 70, height: 70)
                .background {
                    Circle()
                        .fill(BrandPalette.brand)
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add new entry")
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
                    .fill(Color.red)
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

                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
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

    // MARK: - Entry list rows

    private var emptyStateRow: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.headline)
            Text("Tap the plus button below to add an entry")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(BrandPalette.canvas)
    }

    private var folderEmptyStateRow: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No entries in this folder")
                .font(.headline)
            Text("Tap the plus button below, or move entries here using the folder button on an entry.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(BrandPalette.canvas)
    }

    /// List-row badge: aligned with `AddEntryFlowSheet` colors (audio blue, photos green, documents orange/brown).
    private func entryBadge(for inputType: SessionInputType) -> (symbol: String, color: Color) {
        switch inputType {
        case .audio:
            return ("waveform", .blue)
        case .documentScan:
            return ("doc.viewfinder", .orange)
        case .documentImage, .document:
            return ("photo.fill", .green)
        case .documentFile:
            return ("doc.badge.plus", .brown)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Input type badge
            let badge = entryBadge(for: session.inputType)
            Image(systemName: badge.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(badge.color)
                .padding(.top, 3)

            if let title = session.title {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Text(session.transcript.isEmpty ? "No transcript" : session.transcript)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .italic(session.transcript.isEmpty)
                }
                .padding(.vertical, 2)
            }
        }
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

    // MARK: - Document / photo OCR

    private func processDocumentScan(_ scan: VNDocumentCameraScan) async {
        defer { isScanningDocument = false }
        do {
            let transcript = try await DocumentScanService().transcribe(scan: scan)
            try await persistDocumentTranscript(transcript, inputType: .documentScan)
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
            let transcript = try await DocumentScanService().transcribe(images: images)
            try await persistDocumentTranscript(transcript, inputType: .documentImage)
        } catch {
            scanErrorMessage = error.localizedDescription
        }
    }

    private func persistDocumentTranscript(_ transcript: String, inputType: SessionInputType) async throws {
        let session = Session(transcript: transcript, inputType: inputType, folderID: listScope.defaultFolderID)
        try await store.upsert(session)
        await home.loadSessions()
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
            let text = try await DocumentFileExtractService().extractText(from: url)
            try await persistDocumentTranscript(text, inputType: .documentFile)
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
            let transcript = try await DocumentScanService().transcribe(images: [uiImage])
            try await persistDocumentTranscript(transcript, inputType: .documentImage)
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
            let text = try await DocumentFileExtractService().extractText(from: claimedURL)
            try await persistDocumentTranscript(text, inputType: .documentFile)
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
