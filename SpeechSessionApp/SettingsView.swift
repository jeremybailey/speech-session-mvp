import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence
import UniformTypeIdentifiers
import UserNotifications
import PhotosUI
import ImageIO

/// Deliberately reachable only from Settings. Import replaces the local dataset;
/// it never imports authentication or submits processing work.
private struct SettingsDataTransferView: View {
    let store: SessionStore
    @ObservedObject var home: HomeViewModel
    @ObservedObject var health: HealthSummaryModel
    let importing: Bool
    @State private var includeOriginals = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var selectedFile: URL?
    @State private var showPicker = false
    @State private var prepared: PreparedDataImport?
    @State private var selectedImportRecords=Set<UUID>()
    @State private var showReplacementConfirmation = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var busy = false
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var missingCount = 0
    @State private var showMissingConfirmation = false
    @State private var operation: Task<Void, Never>?
    @State private var ownsTransfer = false

    var body: some View {
        Form {
            Section {
                Text("This ZIP file contains sensitive health information. Only share it with people you authorize, use restricted Drive sharing, and send the password separately. Your password cannot be recovered.")
                    .font(StoryDesignTokens.font(.footnote))
            }
            if importing {
                Section {
                    Button(selectedFile == nil ? "Choose ZIP file" : "Choose a different ZIP file") { showPicker = true }
                    if selectedFile != nil { Text("ZIP file selected").foregroundStyle(StoryDesignTokens.secondaryInk) }
                    Text("Enter the password used when this ZIP file was created. Passwords are case-sensitive.")
                        .font(StoryDesignTokens.font(.footnote)).foregroundStyle(StoryDesignTokens.secondaryInk)
                    SecureField("File password", text: $password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Review import") { inspectImport() }
                        .disabled(selectedFile == nil || password.isEmpty)
                }
                .disabled(busy || prepared != nil)
                if let prepared {
                    Section("Import preview") {
                        LabeledContent("Selected records", value: String(selectedImportRecords.count))
                        DisclosureGroup("Choose records to copy") {
                            ForEach(prepared.manifest.records,id:\.id){record in
                                Toggle(record.title ?? "Untitled record",isOn:Binding(get:{selectedImportRecords.contains(record.id)},set:{if $0 {selectedImportRecords.insert(record.id)} else {selectedImportRecords.remove(record.id)}}))
                            }
                        }
                        Text("An untouched copy of the imported ZIP is retained. A partial import includes selected records and their corrections; the previous cross-record narrative and chat are not imported.").font(StoryDesignTokens.font(.footnote))
                        LabeledContent("File created", value: prepared.manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Original files", value: prepared.manifest.includesOriginals ? "Included where available" : "Not included")
                        if prepared.manifest.missingOriginalCount > 0 {
                            Text("\(prepared.manifest.missingOriginalCount) original files were unavailable on the original device.")
                        }
                        Text("Replacing removes this device’s current history and original files. Save a backup ZIP file with originals first if you want to restore it later. Your sign-in will not change. No AI processing starts during import.")
                        Button("Replace local history", role: .destructive) { showReplacementConfirmation = true }
                            .disabled(busy || selectedImportRecords.isEmpty)
                        Button("Cancel import", role: .cancel) { cancelPreview() }.disabled(busy)
                    }
                }
            } else {
                Section {
                    LabeledContent("Records", value: String(home.sessions.count))
                    Toggle("Include original files", isOn: $includeOriginals)
                    Text("Add original audio, PDFs, scans, and photos. Transcripts, extracted text, and saved results are always included.").font(StoryDesignTokens.font(.footnote))
                    Text("Use at least \(DataTransferArchive.minimumPasswordLength) characters. Words and spaces are fine; numbers and symbols are optional.")
                        .font(StoryDesignTokens.font(.footnote)).foregroundStyle(StoryDesignTokens.secondaryInk)
                    SecureField("Choose a password", text: $password)
                        .textContentType(.newPassword)
                    if !password.isEmpty && password.count < DataTransferArchive.minimumPasswordLength {
                        Text("\(DataTransferArchive.minimumPasswordLength - password.count) more characters needed.")
                            .font(StoryDesignTokens.font(.caption)).foregroundStyle(StoryDesignTokens.secondaryInk)
                    }
                    SecureField("Confirm password", text: $confirmation)
                        .textContentType(.newPassword)
                    if !confirmation.isEmpty && password != confirmation {
                        Text("Passwords don’t match yet.")
                            .font(StoryDesignTokens.font(.caption)).foregroundStyle(StoryDesignTokens.secondaryInk)
                    }
                    Button("Create encrypted ZIP") { export() }
                        .disabled(password.count < DataTransferArchive.minimumPasswordLength || password != confirmation)
                }
                .disabled(busy)
                if let _ = shareURL {
                    Section {
                        Button("Share export") { showShare = true }
                        Text("Save or share before leaving this screen. The temporary export is removed when you leave.").font(StoryDesignTokens.font(.footnote))
                    }
                }
            }
            if busy {
                Section {
                    ProgressView(status)
                    Button("Cancel", role: .cancel) { operation?.cancel(); status = "Cancelling safely…" }
                }
            } else if !status.isEmpty { Section { Text(status) } }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(StoryDesignTokens.action) } }
        }
        .storyListCanvas()
        .navigationTitle(importing ? "Import data" : "Export data")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .interactiveDismissDisabled(busy)
        .disabled(!ownsTransfer)
        .onAppear {
            guard !ownsTransfer, !health.isProcessing, !health.isTransferringData else { return }
            health.isTransferringData = true; ownsTransfer = true
        }
        .onDisappear {
            guard ownsTransfer, !showShare, !showPicker else { return }
            ownsTransfer = false
            password = ""; confirmation = ""; operation?.cancel()
            let finishing = operation
            Task { @MainActor in
                await finishing?.value
                try? await store.discardDataTransfer()
                health.isTransferringData = false
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): selectedFile = url; prepared = nil; errorMessage = nil
            case .failure: errorMessage = "The ZIP file could not be opened. Try choosing it again from Files."
            }
        }
        .sheet(isPresented: $showShare) {
            if let shareURL { HealthActivitySheet(urls: [shareURL]) }
        }
        .confirmationDialog("Replace local history?", isPresented: $showReplacementConfirmation, titleVisibility: .visible) {
            Button("Replace local history", role: .destructive) { replace() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current records and originals will be removed. This cannot be undone without a backup ZIP file. Your account stays signed in.")
        }
        .confirmationDialog("Some originals are missing", isPresented: $showMissingConfirmation, titleVisibility: .visible) {
            Button("Continue without missing files") { export(allowMissing: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("\(missingCount) original files cannot be included. Saved source text and results will still be exported.") }
    }

    private func export(allowMissing: Bool = false) {
        guard !busy, ownsTransfer, !health.isProcessing else { return }
        busy = true; status = "Creating encrypted export…"; errorMessage = nil; shareURL = nil
        let secret = password
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") +
                    " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown") + ")"
                let url = try await store.exportData(password: secret, includeOriginals: includeOriginals,
                                                    allowMissingOriginals: allowMissing, appVersion: version)
                try Task.checkCancellation()
                password = ""; confirmation = ""; shareURL = url; showShare = true
                status = "Export ready. Share the password separately."
            } catch DataTransferError.missingOriginals(let count) {
                missingCount = count; showMissingConfirmation = true; status = ""
            } catch {
                password = ""; confirmation = ""
                try? await store.discardDataTransfer()
                status = ""; errorMessage = transferMessage(error)
            }
        }
    }

    private func inspectImport() {
        guard let selectedFile, !busy, ownsTransfer, !health.isProcessing else { return }
        busy = true; status = "Opening and checking ZIP file…"; errorMessage = nil
        let secret = password; password = ""
        operation = Task { @MainActor in
            defer { busy = false }
            let scoped = selectedFile.startAccessingSecurityScopedResource()
            defer { if scoped { selectedFile.stopAccessingSecurityScopedResource() } }
            do {
                prepared = try await store.prepareDataImport(from: selectedFile, password: secret)
                selectedImportRecords=Set(prepared?.manifest.records.map(\.id) ?? [])
                try Task.checkCancellation()
                status = "Review the ZIP file’s contents before replacing your history."
            } catch {
                prepared = nil; try? await store.discardDataTransfer()
                status = ""; errorMessage = transferMessage(error)
            }
        }
    }

    private func cancelPreview() {
        prepared = nil; status = "Import cancelled. Your history is unchanged."
        operation = Task { try? await store.discardDataTransfer() }
    }

    private func replace() {
        guard let prepared, !busy, ownsTransfer, !health.isProcessing else { return }
        busy = true; status = "Replacing local history…"; errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let previousReminderIDs = health.snapshot.preferences.filter(\.reminderEnabled).map(\.id)
                try await store.replaceWithImportedData(prepared,selecting:selectedImportRecords)
                // The replaced person's reminders must not remain on this phone.
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: previousReminderIDs)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: previousReminderIDs)
                // Clear only history-specific defaults. Authentication, consent,
                // transcription configuration, and account spending stay local.
                for key in ["speechSession.pendingSummaryJob", "speechSession.globalSummaryJSON", "speechSession.globalSummaryBackend", "speechSession.globalSummaryFingerprint"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                await health.resetAfterDataImport()
                await home.loadSessions()
                self.prepared = nil; selectedFile = nil
                status = "History imported. No AI processing was started. Use the existing record reprocessing and condition/overview controls when you’re ready."
            } catch {
                self.prepared = nil; try? await store.discardDataTransfer()
                status = ""; errorMessage = transferMessage(error)
            }
        }
    }

    private func transferMessage(_ error: Error) -> String {
        if error is CancellationError { return "Transfer cancelled. Your saved history is unchanged." }
        if let error = error as? DataTransferError { return error.localizedDescription }
        return "The transfer could not finish. Check the ZIP file and available device storage, then try again."
    }
}

struct SettingsView: View {
    /// Drives sheet dismissal from the presenter’s `isPresented` binding so UIKit tears down
    /// presentation cleanly (nested `NavigationStack` + `Environment(\.dismiss)` can leave a
    /// full-screen hit blocker on iPad after the sheet animates out).
    @Binding var isPresented: Bool
    let store: SessionStore
    @ObservedObject var home: HomeViewModel
    @ObservedObject var health: HealthSummaryModel
    var transferIsAvailable: Bool
    var allowsStoryReset = false
    @State private var confirmStoryReset = false
    @ObservedObject private var captureWork = CaptureProcessing.shared
    private var canReset: Bool {
        allowsStoryReset && transferIsAvailable && !health.isProcessing && !health.isUpdatingStory && !health.isTransferringData && captureWork.active.isEmpty
    }

    private func resetHistory() {
        guard canReset else { return }
        health.isTransferringData = true
        Task { @MainActor in
            defer { health.isTransferringData = false }
            do {
                let ids = health.snapshot.preferences.filter(\.reminderEnabled).map(\.id)
                try await store.clearLocalStoryHistory()
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
                for key in ["speechSession.pendingSummaryJob", "speechSession.globalSummaryJSON", "speechSession.globalSummaryBackend", "speechSession.globalSummaryFingerprint", "storyLab.lastViewedPractitionerSummary"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                await health.resetAfterDataImport()
                await home.loadSessions()
                isPresented = false
                NotificationCenter.default.post(name: .storyHistoryCleared, object: nil)
            } catch { settingsActionError = error.localizedDescription }
        }
    }

    @AppStorage("speechSession.transcriptionBackend") private var backendRaw = TranscriptionBackend.onDeviceWhisperKit.rawValue
    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.whisperKitModel") private var whisperKitModel = DeviceCapabilityProfile.tinyWhisperKitModel
    @AppStorage("speechSession.summaryBackend") private var summaryBackendRaw = "openai"
    /// On legacy tier, enables the Base WhisperKit model in addition to Tiny (always allowed).
    @AppStorage("speechSession.whisperKitExperimentalUnlock") private var whisperKitExperimentalUnlock = false
    @EnvironmentObject private var kindeAuth: KindeAuthManager
    @State private var settingsActionError: String?
    @State private var showOnDeviceSummaryOptIn = false
    @State private var aiUsage: AIUsageSnapshot?
    @State private var usageIsStale = false
    @State private var usageRequestID = UUID()

    private var selectedBackend: TranscriptionBackend {
        TranscriptionBackend(rawValue: backendRaw) ?? .onDeviceWhisperKit
    }

    private var capabilityProfile: DeviceCapabilityProfile {
        DeviceCapabilityProfile.current
    }

    private var availableTranscriptionBackends: [TranscriptionBackend] {
        TranscriptionBackend.allCases.filter { backend in
            backend != .onDeviceWhisperKit
                || capabilityProfile.permitsWhisperKit(experimentalUnlocked: whisperKitExperimentalUnlock)
        }
    }

    private let whisperKitModels: [(name: String, label: String)] = [
        ("openai_whisper-tiny.en",   "Tiny (~39 MB) — fastest"),
        ("openai_whisper-base.en",   "Base (~74 MB) — recommended"),
        ("openai_whisper-small.en",  "Small (~244 MB) — more accurate"),
        ("openai_whisper-medium.en", "Medium (~750 MB) — highest accuracy"),
    ]

    private var availableWhisperKitModels: [(name: String, label: String)] {
        let allowed = capabilityProfile.allowedWhisperKitModels(experimentalUnlocked: whisperKitExperimentalUnlock)
        return whisperKitModels.filter { allowed.contains($0.name) }
    }

    // MARK: - WhisperKit download state

    private enum ModelDownloadState: Equatable {
        case checking
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }
    @State private var modelDownloadState: ModelDownloadState = .checking

    var body: some View {
        NavigationStack {
            Form {

                Section {
                    Label {
                        Text("CollectiveCare helps capture and organize visit notes, but it is not medical advice. Review summaries for accuracy before using or sharing them.")
                    } icon: {
                        Image(systemName: "heart.text.square")
                    }
                    .font(StoryDesignTokens.font(.footnote))
                    .foregroundStyle(StoryDesignTokens.secondaryInk)
                } header: {
                    Text("Beta Notice")
                }


                Section {
                    NavigationLink("Export data") {
                        SettingsDataTransferView(store: store, home: home, health: health, importing: false)
                    }
                    NavigationLink("Import data") {
                        SettingsDataTransferView(store: store, home: home, health: health, importing: true)
                    }
                    if allowsStoryReset {
                        Button("Clear health history…", role: .destructive) { confirmStoryReset = true }
                            .disabled(!canReset)
                            .alert("Clear history on this device?", isPresented: $confirmStoryReset) {
                                Button("Cancel", role: .cancel) {}
                                Button("Clear history", role: .destructive) { resetHistory() }
                            } message: {
                                Text("This removes your records, attachments, care plans, summaries and chats from this device. You’ll stay signed in. To restore later, first export a ZIP with originals and save it in Files.")
                            }
                    }
                } header: { Text("Data transfer") }
                footer: {
                    Text("Share a password-protected export or replace this device’s history. Your sign-in does not change. Wait for recording and processing to finish before transferring.")
                }
                .disabled(!transferIsAvailable || health.isProcessing)

                Section {
                    Picker("Engine", selection: $backendRaw) {
                        ForEach(availableTranscriptionBackends, id: \.rawValue) { backend in
                            Text(backend.displayTitle).tag(backend.rawValue)
                        }
                    }
                } header: {
                    Text("Transcription Engine")
                } footer: {
                    Text(transcriptionPrivacyNote)
                }

                #if DEBUG
                Section("Debug") {
                    if !health.categoryReviews.isEmpty {
                        NavigationLink("Review category changes") {WholeHistoryUpdateReviewView(health:health)}
                    }
                    NavigationLink("Update diagnostics") {
                        List {
                            Section("Health story") {
                                LabeledContent("Overview", value: health.overviewIsCurrent ? "Current" : (health.displayedOverview == nil ? "Unavailable" : "Previous version"))
                                if let notice = health.retainedRecordNotice {
                                    Text(notice)
                                }
                                if let error = health.updateError { Text(error) }
                                if let error = health.conditionNotice { Text(error) }
                                if let error = health.overviewNotice { Text(error) }
                            }
                        }
                        .storyListCanvas()
                        .navigationTitle("Update diagnostics")
                    }
                }
                #endif

                Section {
                    LabeledContent("Today", value: usageAmount(aiUsage?.tracking_start == nil ? nil : aiUsage?.today_nusd))
                    LabeledContent("Last 48 hours", value: usageAmount(aiUsage?.tracking_start == nil ? nil : aiUsage?.last48_nusd))
                    LabeledContent("Since tracking began", value: usageAmount(aiUsage?.tracking_start == nil ? nil : aiUsage?.lifetime_nusd))
                    if let usage = aiUsage {
                        NavigationLink("Usage details") {
                            List {
                                Section("Latest processing job") {
                                    if let latest = usage.latest_job {
                                        Text(latest.state)
                                        LabeledContent("Workload", value: latest.workload_type ?? "Unknown")
                                        LabeledContent("Estimated API cost", value: usageAmount(latest.cost_nusd))
                                        LabeledContent("Records", value: latest.record_count.map(String.init) ?? "Unavailable")
                                        LabeledContent("Retries", value: String(latest.retry_count))
                                    } else { Text("No tracked processing yet") }
                                }
                                Section("By stage and model — since tracking began") {
                                    ForEach(usage.breakdown, id: \.self) { Text($0).font(StoryDesignTokens.font(.footnote)) }
                                }
                                Section("Shared pilot budgets") {
                                    ForEach(usage.budgets, id: \.id) { budget in
                                        Text(budget.id)
                                        LabeledContent("Used", value: usageAmount(budget.used_nusd))
                                        LabeledContent("Reserved", value: usageAmount(budget.reserved_nusd))
                                        LabeledContent("Remaining", value: usageAmount(budget.remaining_nusd))
                                    }
                                }
                                Text("Unresolved charges: \(usage.unresolved_charges). These are not included in known costs; their budget remains reserved.")
                            }
                            .storyListCanvas().navigationTitle("AI usage")
                        }
                        Button("Copy usage report") { UIPasteboard.general.string = usage.report }
                    }
                    Button("Refresh usage") { Task { await refreshUsage() } }
                } header: { Text("AI usage · Estimated API cost") }
                footer: {
                    Text("USD. Known costs exclude unresolved charges. Provider billing is authoritative. Infrastructure charges are separate. " +
                         (aiUsage.map { "Tracking began: \($0.tracking_start ?? "Not started"). Last updated: \($0.updated_at)." } ?? "Unavailable. Historical costs have not been reconstructed.") +
                         (usageIsStale ? " Cached figures; refresh unavailable." : ""))
                }

                if !capabilityProfile.supportsWhisperKit {
                    Section {
                        Toggle("WhisperKit on this device (experimental)", isOn: $whisperKitExperimentalUnlock)
                    } footer: {
                        Text(
                            "Tiny is always available on this hardware. Turn on to also allow the Base model (more accurate, heavier). May be slow or run out of memory."
                        )
                    }
                }

                if let reason = capabilityProfile.whisperKitHardBlockReason(experimentalUnlocked: whisperKitExperimentalUnlock) {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(StoryDesignTokens.font(.footnote))
                            .foregroundStyle(StoryDesignTokens.secondaryInk)
                    }
                }

                if selectedBackend == .onDeviceWhisperKit {
                    Section {
                        Picker("Model", selection: $whisperKitModel) {
                            ForEach(availableWhisperKitModels, id: \.name) { m in
                                Text(m.label).tag(m.name)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("WhisperKit Model")
                    }

                    Section {
                        modelStatusRow
                    } header: {
                        Text("Model Status")
                    } footer: {
                        Text("The model is downloaded once and cached on-device. The app prefetches your selected model in the background when possible; you can also download here.")
                    }
                    // Re-check whenever the selected model changes.
                    .task(id: whisperKitModel) {
                        await checkModelStatus()
                    }
                }

                if usesOpenAI {
                    #if DEBUG
                    Section {
                        SecureField("sk-… (debug only)", text: $openAIAPIKey)
                            .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                            .autocorrectionDisabled()
                    } header: {
                        Text("OpenAI API Key (Debug)")
                    } footer: {
                        Text("Optional developer override. Release builds use your CollectiveCare account and organization proxy only.")
                    }
                    #endif
                }

                Section {
                    Picker("Summary Engine", selection: Binding(
                        get: { summaryBackendRaw },
                        set: { choice in
                            if choice == "onDevice", summaryBackendRaw != "onDevice" {
                                showOnDeviceSummaryOptIn = true
                            } else {
                                summaryBackendRaw = choice
                            }
                        }
                    )) {
                        Text("OpenAI (cloud, recommended)").tag("openai")
                        if #available(iOS 26.0, *) {
                            Text("Apple Intelligence (on-device, opt-in)").tag("onDevice")
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Medical Summary Engine")
                } footer: {
                    Text(summaryPrivacyNote)
                }
                if summaryBackendRaw == "onDevice" {
                    if #available(iOS 26.0, *) {
                        if !OnDeviceSummaryService.isAvailable {
                            Section {
                                Label(OnDeviceSummaryService.unavailabilityReason, systemImage: "exclamationmark.triangle")
                                    .font(StoryDesignTokens.font(.footnote))
                                    .foregroundStyle(StoryDesignTokens.secondaryInk)
                            }
                        }
                    }
                }
            }
            .storyListCanvas()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { isPresented = false }
                        .fontWeight(.semibold)
                        .disabled(health.isTransferringData)
                }
            }
            .alert("Settings", isPresented: Binding(
                get: { settingsActionError != nil },
                set: { if !$0 { settingsActionError = nil } }
            )) {
                Button("OK", role: .cancel) { settingsActionError = nil }
            } message: {
                Text(settingsActionError ?? "")
            }
            .confirmationDialog("Use Apple Intelligence for summaries?", isPresented: $showOnDeviceSummaryOptIn, titleVisibility: .visible) {
                Button("Use on-device summaries") { summaryBackendRaw = "onDevice" }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Summary processing stays on this device. Large records can take substantially longer, and condition organization is unavailable in this mode. OpenAI cloud processing is recommended for the faster health-story workflow.")
            }
        }
        .background(BrandPalette.canvas.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(health.isTransferringData)
        .task {
            normalizeSettingsForDevice()
            await refreshUsage()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AIProcessingCompleted"))) { _ in
            Task { await refreshUsage() }
        }
        .onChange(of: backendRaw) { _, _ in
            normalizeSettingsForDevice()
        }
        .onChange(of: whisperKitModel) { _, _ in
            normalizeSettingsForDevice()
        }
        .onChange(of: whisperKitExperimentalUnlock) { _, _ in
            normalizeSettingsForDevice()
        }
        .onChange(of: kindeAuth.isSignedIn) { _, _ in
            aiUsage = nil
            normalizeSettingsForDevice()
            Task { await refreshUsage() }
        }
    }

    // MARK: - Model status row

    private func usageAmount(_ nanoUSD: String?) -> String {
        guard let nanoUSD, let amount = Double(nanoUSD) else { return "Unavailable" }
        return String(format: "$%.4f USD", amount / 1_000_000_000)
    }

    @MainActor private func refreshUsage() async {
        let requestID = UUID()
        usageRequestID = requestID
        guard kindeAuth.isSignedIn, let base = CloudOpenAIConfiguration.proxyBaseURL else {
            aiUsage = nil
            return
        }
        do {
            var url = URLComponents(url: base.appendingPathComponent("v1/health-processing/usage"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)]
            var request = URLRequest(url: url.url!)
            request.setValue("Bearer \(try await kindeAuth.freshAccessToken())", forHTTPHeaderField: "Authorization")
            if FastDetailsConfiguration.experimental { request.setValue("fast-details", forHTTPHeaderField: "X-CollectiveCare-Pipeline") }
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let snapshot = try JSONDecoder().decode(AIUsageSnapshot.self, from: data)
            guard kindeAuth.isSignedIn, usageRequestID == requestID else { return }
            aiUsage = snapshot
            usageIsStale = false
        } catch { if usageRequestID == requestID { usageIsStale = aiUsage != nil } }
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        switch modelDownloadState {
        case .checking:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Checking…").foregroundStyle(StoryDesignTokens.secondaryInk)
            }

        case .notDownloaded:
            HStack {
                Label("Not downloaded", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(StoryDesignTokens.secondaryInk)
                Spacer()
                Button("Download") {
                    Task { await startDownload() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .downloading:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Downloading… this may take a minute")
                    .foregroundStyle(StoryDesignTokens.secondaryInk)
            }

        case .ready:
            Label("Ready to use", systemImage: "checkmark.circle.fill")
                .foregroundStyle(StoryDesignTokens.ink)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Download failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(StoryDesignTokens.action)
                Text(message)
                    .font(StoryDesignTokens.font(.caption))
                    .foregroundStyle(StoryDesignTokens.secondaryInk)
                Button("Retry") {
                    Task { await startDownload() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Download logic

    private func checkModelStatus() async {
        guard capabilityProfile.permitsWhisperKit(experimentalUnlocked: whisperKitExperimentalUnlock),
              capabilityProfile.permitsWhisperKitModel(whisperKitModel, experimentalUnlocked: whisperKitExperimentalUnlock)
        else {
            modelDownloadState = .failed(
                capabilityProfile.whisperKitHardBlockReason(experimentalUnlocked: whisperKitExperimentalUnlock)
                    ?? "This WhisperKit model is not available on this iPhone."
            )
            return
        }
        modelDownloadState = .checking
        let cached = await WhisperKitModelSetup.isModelCached(whisperKitModel)
        modelDownloadState = cached ? .ready : .notDownloaded
    }

    private func startDownload() async {
        guard capabilityProfile.permitsWhisperKit(experimentalUnlocked: whisperKitExperimentalUnlock),
              capabilityProfile.permitsWhisperKitModel(whisperKitModel, experimentalUnlocked: whisperKitExperimentalUnlock)
        else {
            modelDownloadState = .failed(
                capabilityProfile.whisperKitHardBlockReason(experimentalUnlocked: whisperKitExperimentalUnlock)
                    ?? "This WhisperKit model is not available on this iPhone."
            )
            return
        }
        modelDownloadState = .downloading
        do {
            try await WhisperKitModelSetup.downloadModel(whisperKitModel)
            modelDownloadState = .ready
        } catch {
            modelDownloadState = .failed(error.localizedDescription)
        }
    }

    private func normalizeSettingsForDevice() {
        if selectedBackend == .openAIWhisper, !cloudInferenceReady {
            backendRaw = DeviceCapabilityProfile.current.fallbackTranscriptionBackend(
                openAIAPIKey: openAIAPIKey,
                kindeSignedInWithProxy: kindeAuth.isSignedIn && CloudOpenAIConfiguration.hasProxy
            ).rawValue
        }

        if selectedBackend == .onDeviceWhisperKit,
           !capabilityProfile.permitsWhisperKitModel(whisperKitModel, experimentalUnlocked: whisperKitExperimentalUnlock),
           let fallbackModel = availableWhisperKitModels.first?.name {
            whisperKitModel = fallbackModel
        }

        // Keep the user's summary engine choice while signed out. Cloud summaries require sign-in at runtime;
        // do not rewrite AppStorage to Apple on-device on every sign-out (that felt like losing their preference).

        if summaryBackendRaw == "onDevice", !isOnDeviceSummaryAvailable {
            summaryBackendRaw = "openai"
        }
    }

    private var isOnDeviceSummaryAvailable: Bool {
        if #available(iOS 26.0, *) {
            return OnDeviceSummaryService.isAvailable
        }
        return false
    }

    private var cloudInferenceReady: Bool {
        let signedInWithProxy = kindeAuth.isSignedIn && CloudOpenAIConfiguration.hasProxy
        #if DEBUG
        let byok = !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return signedInWithProxy || byok
        #else
        return signedInWithProxy
        #endif
    }

    private var usesOpenAI: Bool {
        selectedBackend == .openAIWhisper || summaryBackendRaw == "openai"
    }

    private var transcriptionPrivacyNote: String {
        switch selectedBackend {
        case .onDeviceApple:
            return "Audio is transcribed with Apple's on-device speech recognition when available."
        case .openAIWhisper:
            return "After recording stops, audio is sent for transcription through your organization’s cloud endpoint when you are signed in."
        case .onDeviceWhisperKit:
            if let reason = capabilityProfile.whisperKitHardBlockReason(experimentalUnlocked: whisperKitExperimentalUnlock) {
                return reason
            }
            if !capabilityProfile.supportsWhisperKit && whisperKitExperimentalUnlock {
                return "Experimental: Base model on older hardware. Tiny is always available; the app prefetches models in the background when possible."
            }
            return "Audio is transcribed on this device with a downloaded WhisperKit model."
        }
    }

    private var summaryPrivacyNote: String {
        if summaryBackendRaw == "onDevice" {
            guard isOnDeviceSummaryAvailable else {
                return "On-device summaries are not available on this iPhone. OpenAI summaries will be used instead."
            }
            return "You are using on-device summaries. Large records can take substantially longer, and condition organization is unavailable in this mode."
        }
        return "Cloud summaries send transcript text through your organization’s API to OpenAI. Entries remain stored on this device."
    }
}

private struct AIUsageSnapshot: Decodable {
    struct Job: Decodable {
        let id: String
        let state: String
        let cost_nusd: String?
        let record_count: Int?
        let retry_count: Int
        let workload_type: String?
    }
    let latest_job: Job?
    struct Entry: Decodable {
        let id: String
        let stage: String
        let model: String
        let state: String
        let cost_nusd: String?
        let reserve_nusd: String
        let retry_count: Int
        let record_count: Int?
        let created_at: String
        let workload_type: String?
    }
    struct Budget: Decodable {
        let id: String
        let limit_nusd: String
        let used_nusd: String
        let reserved_nusd: String
        var remaining_nusd: String? {
            guard let limit = Int64(limit_nusd), let used = Int64(used_nusd),
                  let reserved = Int64(reserved_nusd), limit >= 0, used >= 0, reserved >= 0 else { return nil }
            guard used <= limit, reserved <= limit - used else { return "0" }
            return String(limit - used - reserved)
        }
    }
    let tracking_start: String?
    let updated_at: String
    let today_nusd: String
    let last48_nusd: String
    let lifetime_nusd: String
    let unresolved_charges: Int
    let timezone: String
    let entries: [Entry]
    let budgets: [Budget]

    private func usd(_ value: String?) -> String {
        value.flatMap(Double.init).map { String(format: "$%.6f USD", $0 / 1_000_000_000) } ?? "Unavailable"
    }
    var breakdown: [String] {
        Dictionary(grouping: entries, by: { "\($0.workload_type ?? "unknown") / \($0.stage) / \($0.model) / \($0.retry_count > 0 ? "retry" : "first attempt")" })
            .sorted { $0.key < $1.key }.map { key, rows in
                let total = rows.compactMap { $0.cost_nusd.flatMap(Int64.init) }.reduce(0,+)
                return "\(key): \(usd(String(total))) known; \(rows.filter { $0.cost_nusd == nil }.count) pending/unresolved"
            }
    }
    // Deliberate allowlist: never serialize credentials, source content, names, or filenames.
    var report: String {
        (["Estimated API cost (USD); provider billing is authoritative.",
          "Range: \(tracking_start ?? "Not started") to \(updated_at); timezone: \(timezone)",
          "Today: \(usd(tracking_start == nil ? nil : today_nusd)); rolling 48h: \(usd(tracking_start == nil ? nil : last48_nusd)); lifetime: \(usd(tracking_start == nil ? nil : lifetime_nusd))",
          "Unresolved charges: \(unresolved_charges)",
          "Historical costs before tracking unavailable; infrastructure excluded."] +
         (latest_job.map { ["Latest processing job \($0.id): \($0.state), \(usd($0.cost_nusd)), workload \($0.workload_type ?? "unknown"), records \($0.record_count.map(String.init) ?? "Unavailable"), retries \($0.retry_count)"] } ?? []) + breakdown +
         entries.map { "Job \($0.id): \($0.stage), \($0.model), \($0.state), \(usd($0.cost_nusd)), workload \($0.workload_type ?? "unknown"), retries \($0.retry_count)" } +
         budgets.map { "Shared budget \($0.id): limit \(usd($0.limit_nusd)), used \(usd($0.used_nusd)), reserved \(usd($0.reserved_nusd)), remaining \(usd($0.remaining_nusd))" })
            .joined(separator: "\n")
    }
}


/// Compares a retained original with its validated candidate; no model call is made.
struct WholeHistoryUpdateReviewView: View {
    @ObservedObject var health:HealthSummaryModel
    var body:some View {
        List {
            Section {
                Text("Compare the previous details with the new version before changing how a record is organized. This does not mark its contents as clinically verified.")
                    .font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk)
            }
            if health.categoryReviews.isEmpty {
                Text("There are no retained category changes to review.").foregroundStyle(StoryDesignTokens.secondaryInk)
            }
            ForEach(health.categoryReviews) {review in
                NavigationLink {
                    WholeHistoryRecordReviewView(health:health,review:review)
                } label: {
                    VStack(alignment:.leading,spacing:4) {
                        Text(review.session.title ?? "Original record")
                        Text(review.missingCategories.map(\.displayTitle).sorted().joined(separator:", "))
                            .font(StoryDesignTokens.font(.caption)).foregroundStyle(StoryDesignTokens.secondaryInk)
                    }
                }
            }
        }
        .storyListCanvas()
        .navigationTitle("Review category changes")
    }
}

private struct WholeHistoryRecordReviewView: View {
    @ObservedObject var health:HealthSummaryModel
    let review:WholeHistoryCategoryReview
    @Environment(\.dismiss) private var dismiss
    @State private var confirm=false
    @State private var busy=false
    @State private var errorMessage:String?
    var body:some View {
        List {
            Section {
                Text("These categories appeared in the previous version but are absent from the new one: "+review.missingCategories.map(\.displayTitle).sorted().joined(separator:", ")+". Check that their information is still represented correctly before using the new details.")
                    .font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk)
                DisclosureGroup("Original record") {Text(review.session.transcript).textSelection(.enabled)}
            }
            Section("Previous details in those categories") {
                ForEach(review.previous) {entry in reviewRow(entry)}
            }
            Section("New details for this record") {
                ForEach(review.generated.filter{!$0.isDeleted}) {entry in reviewRow(entry)}
            }
            Section {
                Button("Use new details for this record") {confirm=true}
                    .disabled(busy || health.isProcessing)
            } footer: {
                Text("Your original record and the previous version stay saved. This action does not use your AI allowance. Go back to keep the previous details.")
            }
        }
        .storyListCanvas()
        .navigationTitle("Compare details")
        .confirmationDialog("Use the new organization for this record?",isPresented:$confirm,titleVisibility:.visible) {
            Button("Use new details") {
                busy=true
                Task {
                    do {try await health.acceptCategoryReview(review);dismiss()}
                    catch {errorMessage=error.localizedDescription}
                    busy=false
                }
            }
            Button("Cancel",role:.cancel) {}
        } message: {
            Text("Confirm that the new version preserves the information you want to keep. It remains unverified; previous details stay in this record’s history.")
        }
        .alert("Couldn’t apply this review",isPresented:Binding(get:{errorMessage != nil},set:{if !$0 {errorMessage=nil}})) {
            Button("OK",role:.cancel) {errorMessage=nil}
        } message: {Text(errorMessage ?? "")}
    }
    private func reviewRow(_ entry:SummaryEntry)->some View {
        DisclosureGroup {
            if !entry.details.isEmpty {Text(entry.details).textSelection(.enabled)}
            ForEach(entry.fields.filter{!$0.isMissing && !$0.value.isEmpty}) {field in
                LabeledContent(field.label,value:field.value)
            }
            if let quote=entry.sourceExcerpt,!quote.isEmpty {Text(quote).font(StoryDesignTokens.font(.footnote)).foregroundStyle(StoryDesignTokens.secondaryInk).textSelection(.enabled)}
        } label: {
            VStack(alignment:.leading,spacing:4) {
                Text(entry.title)
                Text(entry.category.displayTitle).font(StoryDesignTokens.font(.caption)).foregroundStyle(StoryDesignTokens.secondaryInk)
            }
        }
    }
}

private struct SettingsProfileView: View {
    @EnvironmentObject private var kindeAuth: KindeAuthManager
    let store: UserProfileStore
    let accountID: String?
    let providerName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var photoData: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var loaded = false
    @State private var saving = false
    @State private var loadingPhoto = false
    @State private var error: String?
    @State private var reloadID = UUID()

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    UserProfileAvatar(photoData: photoData, size: 104)
                    Spacer()
                }.padding(.vertical, 12)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(photoData == nil ? "Add photo" : "Change photo", systemImage: "photo")
                }
                .disabled(!loaded || saving || loadingPhoto)
                if photoData != nil {
                    Button("Remove photo", role: .destructive) { photoData = nil; selectedPhoto = nil; error = nil }
                        .disabled(saving || loadingPhoto)
                }
                if loadingPhoto { ProgressView("Preparing photo…") }
            }
            Section {
                TextField("Your name", text: $name)
                    .textContentType(.name).textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .disabled(!loaded || saving)
                if name.count > UserProfileStore.maximumNameLength {
                    Text("Use a name of \(UserProfileStore.maximumNameLength) characters or fewer.")
                        .font(StoryDesignTokens.caption).foregroundStyle(StoryDesignTokens.action)
                }
            } header: {
                Text("Name")
            } footer: {
                Text(accountID == nil ? "Saved on this device while signed out." : "Saved on this device for this account.")
            }
            if !loaded && error == nil { ProgressView("Loading profile…") }
            if let error {
                Section {
                    Text(error).foregroundStyle(StoryDesignTokens.action)
                    if !loaded { Button("Try again") { reloadID = UUID() } }
                }
            }
        }
        .storyListCanvas()
        .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { save() }
                    .disabled(!loaded || saving || loadingPhoto || name.count > UserProfileStore.maximumNameLength)
            }
        }
        .task(id: reloadID) {
            error = nil
            do {
                if let accountID, let providerName { try await store.seedName(providerName, accountID: accountID) }
                let profile = try await store.load(accountID: accountID)
                try Task.checkCancellation()
                name = profile.name; photoData = profile.photoData; loaded = true
            } catch is CancellationError { }
            catch { self.error = "Your profile couldn’t be loaded. Try again." }
        }
        .task(id: selectedPhoto) {
            guard let selection = selectedPhoto else { return }
            loadingPhoto = true; error = nil
            defer { if selectedPhoto == selection { loadingPhoto = false } }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else { throw UserProfileError.invalidProfile }
                let prepared = try await Task.detached(priority: .userInitiated) { try Self.preparePhoto(data) }.value
                try Task.checkCancellation()
                photoData = prepared
            } catch is CancellationError { }
            catch { self.error = "That photo couldn’t be opened. Try another image." }
        }
    }

    private func save() {
        guard loaded, !saving, !loadingPhoto else { return }
        saving = true; error = nil
        let profile = UserProfile(name: name, photoData: photoData)
        Task { @MainActor in
            defer { saving = false }
            do {
                try await store.save(profile, accountID: accountID)
                await kindeAuth.refreshProfile()
                dismiss()
            }
            catch { self.error = "Your profile couldn’t be saved. Try again." }
        }
    }

    /// A small re-encoded image retains orientation but no original photo metadata.
    nonisolated private static func preparePhoto(_ data: Data) throws -> Data {
        guard data.count <= 30_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary),
              let result = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85),
              result.count <= UserProfileStore.maximumPhotoBytes else { throw UserProfileError.invalidProfile }
        return result
    }
}

/// Shared by the native toolbar menu, account header and photo editor.
struct UserProfileAvatar: View {
    let photoData: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let photoData, let photo = UIImage(data: photoData) {
                Image(uiImage: photo).renderingMode(.original).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(StoryDesignTokens.secondaryInk)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityLabel("Profile photo")
    }
}

struct AccountSettingsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var kindeAuth: KindeAuthManager
    @AppStorage("speechSession.skippedSignInGate") private var skippedSignInGate = false
    @State private var accountActionPending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        UserProfileAvatar(photoData: kindeAuth.userProfile.photoData, size: 88)
                        Text(kindeAuth.userProfile.name.isEmpty ? "Your profile" : kindeAuth.userProfile.name)
                            .font(StoryDesignTokens.sectionHeading).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    if let profileStore = kindeAuth.profileStore {
                        NavigationLink {
                            SettingsProfileView(store: profileStore,
                                                accountID: kindeAuth.isSignedIn ? kindeAuth.accountID : nil,
                                                providerName: kindeAuth.profileName)
                                .id(kindeAuth.isSignedIn ? kindeAuth.accountID : nil)
                        } label: {
                            Label("Name and photo", systemImage: "person.crop.circle")
                        }
                        .disabled(accountActionPending || (kindeAuth.isSignedIn && kindeAuth.accountID == nil))
                    } else {
                        Text("Your profile is unavailable. Try reopening Account.")
                    }
                }
                Section {
                    if kindeAuth.isSignedIn {
                        if let email = kindeAuth.userPreview, !email.isEmpty {
                            LabeledContent("Email", value: email).textSelection(.enabled)
                        }
                        Button("Sign out", role: .destructive) {
                            accountActionPending = true
                            Task { @MainActor in
                                defer { accountActionPending = false }
                                skippedSignInGate = false
                                await kindeAuth.logout()
                            }
                        }.disabled(accountActionPending)
                    } else {
                        Button("Sign in") {
                            accountActionPending = true
                            Task { @MainActor in
                                defer { accountActionPending = false }
                                do { try await kindeAuth.login() }
                                catch { self.error = "Sign-in couldn’t be completed. Please try again." }
                            }
                        }.disabled(accountActionPending)
                    }
                    if accountActionPending { ProgressView("Updating account…") }
                } header: {
                    Text("Sign-in")
                } footer: {
                    Text(kindeAuth.isSignedIn ? "Your saved health records stay on this device when you sign out." : "Sign in to use cloud transcription and summaries.")
                }
            }
            .storyListCanvas()
            .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { isPresented = false }
                        .labelStyle(.iconOnly).disabled(accountActionPending)
                }
            }
            .alert("Sign in", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .background(BrandPalette.canvas.ignoresSafeArea())
        .presentationDetents([.large])
        .interactiveDismissDisabled(accountActionPending)
        .task { await kindeAuth.refreshProfile() }
    }
}
