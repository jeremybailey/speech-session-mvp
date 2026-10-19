import SwiftUI
import SpeechSessionPersistence

/// Root container: account sign-in and a server-recorded pilot agreement before the main UI.
struct AppShellView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var kindeAuth: KindeAuthManager

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var agreement = PilotAgreementState()

    var body: some View {
        Group {
            if !kindeAuth.isSignedIn {
                SignInGateView()
            } else if agreement.acceptedOwner == kindeAuth.accountID, agreement.acceptedOwner != nil {
                ContentView(appModel: appModel)
            } else {
                IntroAgreementView(state: agreement, auth: kindeAuth)
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
        .task(id: kindeAuth.isSignedIn ? kindeAuth.accountID : nil) {
            await agreement.load(auth: kindeAuth)
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
    @ObservedObject var state: PilotAgreementState
    let auth: KindeAuthManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let document = state.document {
                        Text(document.introduction).font(.headline)
                        ForEach(Array(document.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(.init(paragraph))
                        }
                        Text("Acceptance is recorded with your account, date, and agreement version.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(document.action) { Task { await state.accept(auth: auth) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.busy)
                    } else if state.busy {
                        ProgressView("Loading agreement…")
                    }
                    if let error = state.error {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry") { Task { await state.load(auth: auth) } }.disabled(state.busy)
                    }
                    Button("Sign out") { Task { await auth.logout() } }.disabled(state.busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .background(BrandPalette.canvas.ignoresSafeArea())
            .navigationTitle("Before you begin")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

@MainActor
private final class PilotAgreementState: ObservableObject {
    typealias Document = PilotAgreementDocument
    typealias Envelope = PilotAgreementEnvelope
    @Published var document: Document?
    @Published var acceptedOwner: String?
    @Published var busy = false
    @Published var error: String?
    private var operation = UUID()

    func load(auth: KindeAuthManager) async {
        let operationID = UUID(); operation = operationID
        acceptedOwner = nil; document = nil; error = nil; busy = false
        guard auth.isSignedIn, let owner = auth.accountID else { busy = false; return }
        // Only cache a server-issued receipt, scoped to the authenticated account.
        if let cached = UserDefaults.standard.data(forKey: "pilotAgreement.receipt.\(owner)"),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: cached), envelope.accepted(by: owner) {
            acceptedOwner = owner
            return
        }
        busy = true
        defer { if operation == operationID { busy = false } }
        do {
            let envelope = try await request(auth: auth, body: nil)
            guard operation == operationID, auth.accountID == owner, auth.isSignedIn else { return }
            guard envelope.agreement.valid else { throw URLError(.cannotParseResponse) }
            document = envelope.agreement
            if envelope.accepted(by: owner) { try save(envelope, owner: owner) }
        } catch {
            guard operation == operationID else { return }
            self.error = "The agreement could not be loaded. Connect to the internet and retry."
        }
    }

    func accept(auth: KindeAuthManager) async {
        guard !busy, let document, let owner = auth.accountID else { return }
        let operationID = operation
        busy = true; error = nil
        defer { if operation == operationID { busy = false } }
        do {
            let body = ["version": document.version, "sha256": document.sha256, "action": document.action,
                        "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                        "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
            let envelope = try await request(auth: auth, body: body)
            guard operation == operationID, auth.accountID == owner, auth.isSignedIn else { return }
            guard envelope.accepted(by: owner), envelope.agreement.sha256 == document.sha256 else {
                throw URLError(.cannotParseResponse)
            }
            try save(envelope, owner: owner)
        } catch {
            guard operation == operationID else { return }
            self.error = "Your acceptance could not be confirmed. Retry to check its status; you will not create a duplicate receipt."
        }
    }

    private func save(_ envelope: Envelope, owner: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(envelope), forKey: "pilotAgreement.receipt.\(owner)")
        acceptedOwner = owner
    }

    private func request(auth: KindeAuthManager, body: [String: String]?) async throws -> Envelope {
        guard let base = CloudOpenAIConfiguration.proxyBaseURL else { throw URLError(.badURL) }
        var request = URLRequest(url: base.appendingPathComponent("v1/agreements/pilot"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(try await auth.freshAccessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }
}

// MARK: - Sign-in gate

struct SignInGateView: View {
    @EnvironmentObject private var kindeAuth: KindeAuthManager
    @Environment(\.scenePhase) private var scenePhase


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
