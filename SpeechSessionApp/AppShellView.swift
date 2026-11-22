import SwiftUI
import SpeechSessionPersistence

/// Root container: account sign-in and a server-recorded pilot agreement before the main UI.
struct AppShellView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var kindeAuth: KindeAuthManager

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var agreement = PilotAgreementState()

    private var storyFixture:Bool {
        #if DEBUG
        return Bundle.main.bundleIdentifier == "com.CollectiveCare.pilot" && ProcessInfo.processInfo.arguments.contains("--storylab-fixture")
        #else
        return false
        #endif
    }
    var body: some View {
        Group {
            if storyFixture {
                ContentView(appModel:appModel)
            } else if !kindeAuth.isSignedIn {
                SignInGateView()
            } else if let owner = agreement.acceptedOwner, owner == kindeAuth.accountID {
                PilotUpdateGate(owner: owner) {
                    ContentView(appModel: appModel)
                } notes: { acknowledge in
                    IntroAgreementView(state: agreement, auth: kindeAuth, acknowledge: acknowledge)
                }
                .id(agreement.acceptedOwner)
            } else {
                IntroAgreementView(state: agreement, auth: kindeAuth)
            }
        }
        .environmentObject(kindeAuth)
        .font(StoryDesignTokens.body)
        .foregroundStyle(StoryDesignTokens.ink)
        .tint(StoryDesignTokens.action)
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

private struct PilotUpdateGate<Content: View, Notes: View>: View {
    @AppStorage private var seen: Bool
    let content: () -> Content
    let notes: (@escaping () -> Void) -> Notes

    init(owner: String, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder notes: @escaping (@escaping () -> Void) -> Notes) {
        _seen = AppStorage(wrappedValue: false, pilotUpdateReceiptKey(owner))
        self.content = content
        self.notes = notes
    }

    var body: some View {
        if seen { content() } else { notes { seen = true } }
    }
}

private func pilotUpdateReceiptKey(_ owner: String) -> String { "pilot.update.capture-timeline-conditions." + owner }

private struct IntroAgreementView: View {
    @ObservedObject var state: PilotAgreementState
    let auth: KindeAuthManager
    var acknowledge: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    welcome
                    if let acknowledge {
                        Button(action: acknowledge) {
                            Text("Continue to my health story")
                                .font(StoryDesignTokens.font(.headline, weight: .semibold))
                                .foregroundStyle(StoryDesignTokens.onAction)
                        }
                        .storyControlStyle(prominent: true)
                    } else if let document = state.document {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Before you begin")
                                .font(StoryDesignTokens.sectionHeading).accessibilityAddTraits(.isHeader)
                            Text(document.introduction)
                                .foregroundStyle(StoryDesignTokens.secondaryInk)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(document.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                                Text(.init(agreementDisplayText(paragraph)))
                                    .font(StoryDesignTokens.font(.body)).lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(20)
                                if index < document.paragraphs.count - 1 {
                                    Divider().padding(.horizontal, 20)
                                }
                            }
                        }
                        .background(BrandPalette.canvas, in: RoundedRectangle(cornerRadius: 24))
                        VStack(spacing: 14) {
                            Label("Your acceptance is recorded with your account, date, and agreement version.", systemImage: "checkmark.shield")
                                .font(StoryDesignTokens.font(.footnote)).foregroundStyle(StoryDesignTokens.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Button { Task { await state.accept(auth: auth) } } label: {
                                HStack(spacing: 10) {
                                    if state.busy { ProgressView().tint(StoryDesignTokens.onAction) }
                                    Text(state.busy ? "Confirming…" : document.action)
                                        .font(StoryDesignTokens.font(.headline, weight: .semibold))
                                }
                                .foregroundStyle(StoryDesignTokens.onAction)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                            }
                            .storyControlStyle(prominent: true)
                            .buttonBorderShape(.roundedRectangle(radius: 16))
                            .disabled(state.busy)
                            Text("Agreement \(document.version)")
                                .font(StoryDesignTokens.font(.caption)).foregroundStyle(StoryDesignTokens.secondaryInk)
                        }
                    } else if state.busy {
                        StoryLoadingPlaceholder(label: "Loading agreement", rows: 2, layout: .narrative)
                            .frame(maxWidth: .infinity).padding(24)
                    }
                    if let error = state.error {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk)
                            Button("Retry") { Task { await state.load(auth: auth) } }.disabled(state.busy)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BrandPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if acknowledge == nil { Button("Sign out") { Task { await auth.logout() } }
                        .font(StoryDesignTokens.font(.subheadline)).frame(maxWidth: .infinity).disabled(state.busy) }
                }
                .frame(maxWidth: 640).padding(.horizontal, 20).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(BrandPalette.canvas.ignoresSafeArea())
            .storyLoadIn(ready: !state.busy || state.document != nil)
            .navigationTitle("CollectiveCare")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // Presentation-only whitespace: keep the signed document and receipt hash unchanged.
    private func agreementDisplayText(_ paragraph: String) -> String {
        guard let start = paragraph.range(of: "**"),
              let end = paragraph.range(of: "**", range: start.upperBound..<paragraph.endIndex) else { return paragraph }
        let heading = String(paragraph[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: #"\s*/\s*"#, with: " / ", options: .regularExpression)
        return String(paragraph[..<start.upperBound]) + heading + String(paragraph[end.lowerBound...])
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("PILOT UPDATE")
                    .font(StoryDesignTokens.font(.caption, weight: .semibold)).tracking(2)
                    .foregroundStyle(BrandPalette.icon)
                Text("Your health story,\nbrought together.")
                    .font(StoryDesignTokens.pageTitle).fixedSize(horizontal: false, vertical: true)
                Text("Your pilot feedback shaped three changes.")
                    .font(StoryDesignTokens.font(.body)).foregroundStyle(StoryDesignTokens.secondaryInk)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("In this update").font(StoryDesignTokens.sectionHeading)
                    Spacer()
                    Text(releaseLabel).font(StoryDesignTokens.font(.caption)).foregroundStyle(StoryDesignTokens.secondaryInk)
                }
                releaseFeature("plus.circle", "Capture information your way", "Tap + to record a visit or voice journal, write a note, take a photo, or upload a file. Tap Done and we’ll extract the details into an editable summary.")
                releaseFeature("bubble.left", "Find what matters now", "Browse your records in a timeline, or tap Ask anything. Try “What are my triglyceride levels?” or “What medications am I taking?” Tap a reference to open the record behind the answer.")
                releaseFeature("folder", "Organize records by condition", "Conditions work like folders. Create your own, move a record, or file it under more than one condition. Its extracted details go with it.")

            }
        }
    }

    private var releaseLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Pilot"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }

    private func releaseFeature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(BrandPalette.icon)
                .frame(width: 38, height: 38)
                .background(BrandPalette.conditionIconBackground, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(StoryDesignTokens.font(.subheadline, weight: .bold))
                Text(detail).font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            UserDefaults.standard.set(true, forKey: pilotUpdateReceiptKey(owner))
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

                VStack(spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 40)).foregroundStyle(StoryDesignTokens.action)
                        .accessibilityHidden(true)
                    Text("CollectiveCare")
                        .font(StoryDesignTokens.pageTitle)
                        .multilineTextAlignment(.center)
                }

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
                                    .font(StoryDesignTokens.font(.headline, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .foregroundStyle(StoryDesignTokens.onAction)
                        .padding(.vertical, 14)
                    }
                    .storyControlStyle(prominent: true)
                    .disabled(isSigningIn)


                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity)
            .background(BrandPalette.canvas.ignoresSafeArea())
            .storyLoadIn().navigationTitle("")
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
