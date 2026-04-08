import SwiftUI
import SpeechSessionFeatures

struct SettingsView: View {
    @AppStorage("speechSession.transcriptionBackend") private var backendRaw = TranscriptionBackend.onDeviceApple.rawValue
    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.whisperKitModel") private var whisperKitModel = "openai_whisper-base.en"
    @AppStorage("speechSession.summaryBackend") private var summaryBackendRaw = "openai"
    @Environment(\.dismiss) private var dismiss

    private var selectedBackend: TranscriptionBackend {
        TranscriptionBackend(rawValue: backendRaw) ?? .onDeviceApple
    }

    private let whisperKitModels: [(name: String, label: String)] = [
        ("openai_whisper-tiny.en",   "Tiny (~39 MB) — fastest"),
        ("openai_whisper-base.en",   "Base (~74 MB) — recommended"),
        ("openai_whisper-small.en",  "Small (~244 MB) — more accurate"),
        ("openai_whisper-medium.en", "Medium (~750 MB) — highest accuracy"),
    ]

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
                Section("Transcription Engine") {
                    Picker("Engine", selection: $backendRaw) {
                        ForEach(TranscriptionBackend.allCases, id: \.rawValue) { backend in
                            Text(backend.displayTitle).tag(backend.rawValue)
                        }
                    }
                }

                if selectedBackend == .onDeviceWhisperKit {
                    Section {
                        Picker("Model", selection: $whisperKitModel) {
                            ForEach(whisperKitModels, id: \.name) { m in
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
                        Text("The model is downloaded once and cached on-device. You must download before recording.")
                    }
                    // Re-check whenever the selected model changes.
                    .task(id: whisperKitModel) {
                        await checkModelStatus()
                    }
                }

                if selectedBackend == .openAIWhisper {
                    Section {
                        SecureField("sk-…", text: $openAIAPIKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                    } header: {
                        Text("OpenAI API Key")
                    } footer: {
                        Text("Used for Whisper transcription and medical summaries. Stored only on this device.")
                    }
                }

                Section("Medical Summary Engine") {
                    Picker("Summary Engine", selection: $summaryBackendRaw) {
                        Text("OpenAI (cloud)").tag("openai")
                        if #available(iOS 26.0, *) {
                            Text("On-device (Apple Intelligence)").tag("onDevice")
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
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
        modelDownloadState = .checking
        let cached = await WhisperKitModelSetup.isModelCached(whisperKitModel)
        modelDownloadState = cached ? .ready : .notDownloaded
    }

    private func startDownload() async {
        modelDownloadState = .downloading
        do {
            try await WhisperKitModelSetup.downloadModel(whisperKitModel)
            modelDownloadState = .ready
        } catch {
            modelDownloadState = .failed(error.localizedDescription)
        }
    }
}
