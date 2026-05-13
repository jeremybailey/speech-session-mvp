import SwiftUI

/// Root container: mandatory sign-in (Kinde) before main UI, with optional Skip for testing / incidents.
/// Settings continues to offer Sign in / Sign out; signing out clears Skip so this gate can appear again.
struct AppShellView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var kindeAuth: KindeAuthManager

    @AppStorage("speechSession.skippedSignInGate") private var skippedSignInGate = false

    private var mayUseMainApp: Bool {
        kindeAuth.isSignedIn || skippedSignInGate
    }

    var body: some View {
        Group {
            if mayUseMainApp {
                ContentView(appModel: appModel)
            } else {
                SignInGateView()
            }
        }
        .environmentObject(kindeAuth)
        .onOpenURL { url in
            guard !KindeAuthManager.isKindeOAuthCallbackURL(url) else { return }
            SharedImportURLInbox.shared.enqueue(url)
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
