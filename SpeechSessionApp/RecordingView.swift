import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

struct RecordingView: View {
    @ObservedObject var vm: RecordingViewModel
    let transcriptionBackend: TranscriptionBackend
    let openAIAPIKey: String
    let whisperKitModel: String
    let store: SessionStore
    let onStopped: (Session?) -> Void

    private enum Phase: Equatable {
        case recording
        case transcribing   // batch backends: waiting for result
        case done(Session)
    }

    @State private var phase: Phase = .recording
    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0

    var body: some View {
        Group {
            switch phase {
            case .recording, .transcribing:
                recordingView
            case .done(let session):
                doneView(session: session)
            }
        }
        .navigationTitle(phase == .recording || phase == .transcribing ? "Recording" : "Saved")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task {
            vm.prepareForRecording(
                backend: transcriptionBackend,
                openAIAPIKey: openAIAPIKey,
                whisperKitModel: whisperKitModel
            )
            await vm.start()
        }
    }

    // MARK: - Recording phase

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(formattedElapsed(vm.elapsed))
                .font(.title2.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .center)
                .contentTransition(.numericText())

            ScrollView {
                Text(livePlaceholder)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            if !batchInfoText.isEmpty && phase == .recording {
                Text(batchInfoText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            if phase == .transcribing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Transcribing…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }

            if let err = vm.errorMessage {
                Text(err).foregroundStyle(.red).font(.footnote)
            }

            Button {
                Task {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        phase = .transcribing
                    }
                    let session = await vm.stop()
                    if let session {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                            phase = .done(session)
                        }
                        // Notify HomeView to refresh the list — but don't navigate yet.
                        onStopped(nil)
                    } else {
                        withAnimation { phase = .recording }
                    }
                }
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(phase == .transcribing)
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: phase == .transcribing)
    }

    // MARK: - Done phase

    private func doneView(session: Session) -> some View {
        VStack(spacing: 0) {
            // Confirmation header
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                    .scaleEffect(checkmarkScale)
                    .opacity(checkmarkOpacity)
                    .onAppear {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                            checkmarkScale = 1.0
                            checkmarkOpacity = 1.0
                        }
                    }
                Text("Recording saved")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .modifier(GlassRectModifier())

            Divider()

            // Transcript preview
            ScrollView {
                Text(session.transcript.isEmpty ? "(No speech detected)" : session.transcript)
                    .font(.body)
                    .foregroundStyle(session.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Divider()

            // Actions
            VStack(spacing: 10) {
                Button {
                    onStopped(session)
                } label: {
                    Label("View Session", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Done") {
                    // Just go back to the list without pushing detail.
                    onStopped(nil)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    // MARK: - Helpers

    private var livePlaceholder: String {
        if vm.liveTranscript.isEmpty, vm.activeSessionUsesWhisper {
            return "Recording… transcript will appear when you stop."
        }
        return vm.liveTranscript.isEmpty ? "Listening…" : vm.liveTranscript
    }

    private var batchInfoText: String {
        switch transcriptionBackend {
        case .openAIWhisper:
            return "Audio is transcribed by OpenAI after you stop — no live text during recording."
        case .onDeviceWhisperKit:
            return "Transcribing on-device after you stop — no data leaves your device."
        default:
            return ""
        }
    }

    private func formattedElapsed(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Liquid Glass modifier (iOS 26+, graceful fallback)

private struct GlassRectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Rectangle())
        } else {
            content.background(.regularMaterial)
        }
    }
}
