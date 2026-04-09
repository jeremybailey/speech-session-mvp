import SwiftUI
import VisionKit
import SpeechSessionFeatures
import SpeechSessionPersistence

struct HomeView: View {
    @ObservedObject var home: HomeViewModel
    @ObservedObject var recording: RecordingViewModel
    let store: SessionStore

    @AppStorage("speechSession.transcriptionBackend") private var backendRaw = TranscriptionBackend.onDeviceApple.rawValue
    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.whisperKitModel") private var whisperKitModel = "openai_whisper-base.en"

    @State private var showSettings = false
    @State private var pulseAnimation = false
    @State private var showDocumentScanner = false
    @State private var isScanningDocument = false
    @State private var scanErrorMessage: String? = nil
    @State private var showRecordingError = false

    private var selectedBackend: TranscriptionBackend {
        TranscriptionBackend(rawValue: backendRaw) ?? .onDeviceApple
    }

    // Derive recording phase purely from the ViewModel — no duplicate state.
    private enum RecordingPhase { case idle, recording, transcribing, scanTranscribing }
    private var phase: RecordingPhase {
        if isScanningDocument { return .scanTranscribing }
        if recording.isFinishingWhisper { return .transcribing }
        if recording.isRecording { return .recording }
        return .idle
    }

    var body: some View {
        List {
            if home.sessions.isEmpty && phase == .idle {
                emptyStateRow
            } else {
                ForEach(home.sessions) { session in
                    NavigationLink(value: session) {
                        sessionRow(session)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let session = home.sessions[index]
                        Task { await home.delete(session: session) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .animation(.default, value: home.sessions.map(\.id))
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .disabled(phase != .idle)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Menu {
                    Button {
                        Task {
                            recording.prepareForRecording(
                                backend: selectedBackend,
                                openAIAPIKey: openAIAPIKey,
                                whisperKitModel: whisperKitModel
                            )
                            await recording.start()
                        }
                    } label: {
                        Label("Transcribe Audio", systemImage: "mic.fill")
                    }
                    Button {
                        scanErrorMessage = nil
                        showDocumentScanner = true
                    } label: {
                        Label("Scan Documents", systemImage: "camera.fill")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                }
            }
        }
        // Hide the bottom toolbar while recording/scanning so the pill takes over.
        .toolbar(phase == .idle ? .visible : .hidden, for: .bottomBar)
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
        // safeAreaInset is only used for the active-state pills now.
        // contentShape blocks touches from falling through to list rows beneath.
        .safeAreaInset(edge: .bottom) {
            activePillControl
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .task {
            await home.loadSessions()
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
    }

    // MARK: - Active-state pill (shown in safeAreaInset while recording / transcribing / scanning)

    @ViewBuilder
    private var activePillControl: some View {
        switch phase {
        case .idle:
            // Error banners shown here when idle so they don't interfere with the toolbar button.
            VStack(spacing: 4) {
                if showRecordingError, let error = recording.errorMessage {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
                if let error = scanErrorMessage {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 8)

        case .recording:
            recordingPill.padding(.bottom, 16)

        case .transcribing:
            transcribingPill.padding(.bottom, 16)

        case .scanTranscribing:
            scanTranscribingPill.padding(.bottom, 16)
        }
    }

    // Scanning document pill — OCR in progress
    private var scanTranscribingPill: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.85)
            Text("Reading document…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .frame(height: 56)
        .modifier(GlassCapsuleModifier())
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
            .modifier(GlassCapsuleModifier())
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
        .modifier(GlassCapsuleModifier())
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: - Session list rows

    private var emptyStateRow: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.headline)
            Text("Tap the mic button to record your visit")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Input type badge
            Image(systemName: session.inputType == .document ? "camera.fill" : "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(session.inputType == .document ? Color.green : Color.blue)
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

    // MARK: - Document scan processing

    private func processDocumentScan(_ scan: VNDocumentCameraScan) async {
        do {
            let transcript = try await DocumentScanService().transcribe(scan: scan)
            let session = Session(transcript: transcript, inputType: .document)
            try? await store.upsert(session)
            await home.loadSessions()
        } catch {
            scanErrorMessage = error.localizedDescription
        }
        isScanningDocument = false
    }
}

private extension Text {
    func italic(_ condition: Bool) -> Text {
        condition ? self.italic() : self
    }
}

// MARK: - Liquid Glass modifiers (iOS 26+, graceful fallback)

private struct GlassCircleModifier: ViewModifier {
    var tint: Color = .blue
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Circle())
        } else {
            content
                .background(tint, in: Circle())
                .shadow(color: tint.opacity(0.35), radius: 10, y: 4)
        }
    }
}

private struct GlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}
