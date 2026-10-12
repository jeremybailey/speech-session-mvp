import SwiftUI

/// Root container: mandatory sign-in (Kinde) before main UI, with optional Skip for testing / incidents.
/// Settings continues to offer Sign in / Sign out; signing out clears Skip so this gate can appear again.
struct AppShellView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var kindeAuth: KindeAuthManager

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("speechSession.skippedSignInGate") private var skippedSignInGate = false
    @AppStorage("collectivecare.introAgreementAccepted") private var introAgreementAccepted = false

    private var mayUseMainApp: Bool {
        kindeAuth.isSignedIn || skippedSignInGate
    }

    var body: some View {
        Group {
            if !introAgreementAccepted {
                IntroAgreementView {
                    introAgreementAccepted = true
                }
            } else if mayUseMainApp {
                ContentView(appModel: appModel)
            } else {
                SignInGateView()
            }
        }
        .environmentObject(kindeAuth)
        // Keep ordinary interactive controls and links consistently blue even when the
        // marketing accent color changes. Destructive controls retain their explicit role.
        .tint(BrandPalette.systemBlue)
        .onOpenURL { url in
            guard !KindeAuthManager.isKindeOAuthCallbackURL(url) else { return }
            if url.scheme == "collectivecare", url.host == "record-start" {
                NotificationCenter.default.post(name: .liveActivityStartRecording, object: nil)
                return
            }
            SharedImportURLInbox.shared.enqueue(url)
        }
        .alert("Cloud session needs attention", isPresented: Binding(
            get: { kindeAuth.sessionNotice != nil },
            set: { if !$0 { kindeAuth.sessionNotice = nil } }
        )) {
            Button("Sign in") {
                Task {
                    do { try await kindeAuth.login() }
                    catch { kindeAuth.sessionNotice = "Sign-in did not finish. Try again in Settings." }
                }
            }
            Button("Later", role: .cancel) { kindeAuth.sessionNotice = nil }
        } message: {
            Text(kindeAuth.sessionNotice ?? "")
        }
        .task { await kindeAuth.refreshSessionIfNeeded() }
        .task {
            await appModel.syncRecordingLiveActivity()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await kindeAuth.refreshSessionIfNeeded() }
            Task {
                await appModel.handleLiveActivityStopIfNeeded()
                appModel.handleLiveActivityStartIfNeeded()
                await appModel.syncRecordingLiveActivity()
            }
        }
        .onChange(of: appModel.recording.isRecording) { _, isRecording in
            if isRecording {
                RecordingLiveActivityBridge.clearPendingCommands()
            }
            Task { await appModel.syncRecordingLiveActivity() }
        }
        .onChange(of: appModel.recording.isFinishingWhisper) { _, _ in
            Task { await appModel.syncRecordingLiveActivity() }
        }
        .onChange(of: appModel.recording.isTranscribingFile) { _, _ in
            Task { await appModel.syncRecordingLiveActivity() }
        }
        .onChange(of: appModel.recording.isCaptureInterrupted) { _, _ in
            Task { await appModel.syncRecordingLiveActivity() }
        }
    }
}

// MARK: - Intro agreement

private struct IntroAgreementView: View {
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("By using this app, you acknowledge and agree:")
                        .font(.headline)

                    Text("1. **Pilot / experimental.** This is an MVP pilot. It may contain errors, lose data, or stop working. It is provided “as is,” without warranties of any kind.")

                    Text("2. **Not medical care.** The app does not provide medical advice, diagnosis, or treatment and is not a substitute for a physician or other qualified provider. Do not rely on it for health decisions. Seek professional care for medical concerns, including emergencies.")

                    Text("3. **Your data.** You enter and control the information, including personal health information such as lab results and medication notes. You are responsible for its accuracy and for what you choose to add, store, or share. Data is stored on your device. Deleting the app or data may permanently remove it; there is no guarantee of backup or recovery.")

                    Text("4. **AI summaries.** Information you choose to process may be summarized by AI. Summaries can be incomplete, inaccurate, or misleading. They are not clinical interpretations. You should review the results against the source records yourself.")

                    Text("5. **Sharing.** Any sharing is initiated by you. You are responsible for the recipient and for any further use or disclosure by them.")

                    Text("6. **Assumption of risk and release.** To the maximum extent permitted by law, you assume all risk of use and release the maker and its personnel from claims arising from the app, including data loss, inaccurate summaries, reliance on outputs, or sharing, except where liability cannot legally be limited.")

                    Text("7. **Age.** You confirm you are 18 or older, or using the app with authority to consent for the account holder.")

                    Button(action: onAccept) {
                        Text("I agree and continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(BrandPalette.canvas.ignoresSafeArea())
            .navigationTitle("Before you begin")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Sign-in gate

struct SignInGateView: View {
    @EnvironmentObject private var kindeAuth: KindeAuthManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("speechSession.skippedSignInGate") private var skippedSignInGate = false

    @State private var isSigningIn = false
    @State private var signInError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                Text("CollectiveCare")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)

                Spacer(minLength: 32)

                VStack(spacing: 14) {
                    Button {
                        Task { await runSignIn() }
                    } label: {
                        Group {
                            if isSigningIn {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Sign in or sign up")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSigningIn)

                    Button("Skip for now (testing)") {
                        skippedSignInGate = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(isSigningIn)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .liquidGlassCard(cornerRadius: 20)
                .padding(.horizontal, 20)

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity)
            .background(BrandPalette.canvas.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            kindeAuth.syncState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            kindeAuth.syncState()
        }
        .alert("Couldn’t sign in", isPresented: Binding(
            get: { signInError != nil },
            set: { if !$0 { signInError = nil } }
        )) {
            Button("OK", role: .cancel) { signInError = nil }
        } message: {
            if let signInError {
                Text(signInError)
            }
        }
    }

    private func runSignIn() async {
        signInError = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await kindeAuth.login()
            kindeAuth.syncState()
        } catch {
            signInError = error.localizedDescription
        }
    }
}
