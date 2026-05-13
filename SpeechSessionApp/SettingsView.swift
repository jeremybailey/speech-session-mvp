import SwiftUI
import SpeechSessionFeatures

struct SettingsView: View {
    @AppStorage("speechSession.transcriptionBackend") private var backendRaw = TranscriptionBackend.onDeviceWhisperKit.rawValue
    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.whisperKitModel") private var whisperKitModel = DeviceCapabilityProfile.tinyWhisperKitModel
    @AppStorage("speechSession.summaryBackend") private var summaryBackendRaw = "openai"
    /// On legacy tier, enables the Base WhisperKit model in addition to Tiny (always allowed).
    @AppStorage("speechSession.whisperKitExperimentalUnlock") private var whisperKitExperimentalUnlock = false
    @AppStorage("speechSession.skippedSignInGate") private var skippedSignInGate = false
    @EnvironmentObject private var kindeAuth: KindeAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var accountActionError: String?

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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Beta Notice")
                }

                Section {
                    if kindeAuth.isSignedIn {
                        if let email = kindeAuth.userPreview, !email.isEmpty {
                            LabeledContent("Signed in", value: email)
                        } else {
                            Text("Signed in")
                                .foregroundStyle(.secondary)
                        }
                        Button("Sign Out", role: .destructive) {
                            Task {
                                skippedSignInGate = false
                                await kindeAuth.logout()
                            }
                        }
                    } else {
                        Button("Sign In") {
                            Task {
                                do {
                                    try await kindeAuth.login()
                                } catch {
                                    accountActionError = error.localizedDescription
                                }
                            }
                        }
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text(accountFooterText)
                }

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
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                            .autocorrectionDisabled()
                    } header: {
                        Text("OpenAI API Key (Debug)")
                    } footer: {
                        Text("Optional developer override. Release builds use your CollectiveCare account and organization proxy only.")
                    }
                    #endif
                }

                Section {
                    Picker("Summary Engine", selection: $summaryBackendRaw) {
                        Text("OpenAI (cloud)").tag("openai")
                        if #available(iOS 26.0, *) {
                            Text("On-device (Apple Intelligence)").tag("onDevice")
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
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Account", isPresented: Binding(
                get: { accountActionError != nil },
                set: { if !$0 { accountActionError = nil } }
            )) {
                Button("OK", role: .cancel) { accountActionError = nil }
            } message: {
                Text(accountActionError ?? "")
            }
        }
        .background(BrandPalette.canvas)
        .task {
            normalizeSettingsForDevice()
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
            normalizeSettingsForDevice()
        }
    }

    // MARK: - Model status row

    @ViewBuilder
    private var modelStatusRow: some View {
        switch modelDownloadState {
        case .checking:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Checking…").foregroundStyle(.secondary)
            }

        case .notDownloaded:
            HStack {
                Label("Not downloaded", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }

        case .ready:
            Label("Ready to use", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Download failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var accountFooterText: String {
        if kindeAuth.isSignedIn, CloudOpenAIConfiguration.hasProxy {
            return "Cloud transcription and summaries use your CollectiveCare account. Visit content stays on this device; only what each feature needs is sent to your organization’s API."
        }
        if kindeAuth.isSignedIn, !cloudOpenAIBaseURLConfigured {
            return "This app build is missing the proxy API URL (CloudOpenAIBaseURL). Cloud OpenAI features need that endpoint—see your organization’s setup guide."
        }
        return "Sign in to use OpenAI Whisper or cloud summaries. Your OpenAI API key is not used in release builds."
    }

    /// Non-empty `CloudOpenAIBaseURL` entry in Info.plist (see docs).
    private var cloudOpenAIBaseURLConfigured: Bool {
        CloudOpenAIConfiguration.hasProxy
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
            return "Summaries are generated on this device when Apple Intelligence is available. "
                + "For stricter grouping of treatment plans and clinical details, testers often prefer OpenAI (cloud)."
        }
        return "Cloud summaries send transcript text through your organization’s API to OpenAI. Entries remain stored on this device."
    }
}
