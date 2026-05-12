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

private enum SignInGatePalette {
    /// Screen background #FFF4E8
    static let canvas = Color(red: 255 / 255, green: 244 / 255, blue: 232 / 255)
    /// Brand / logotype / primary CTA fill #38244A
    static let brand = Color(red: 56 / 255, green: 36 / 255, blue: 74 / 255)
    /// Label on filled CTA
    static let ctaLabel = Color.white
}

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
                    .foregroundStyle(SignInGatePalette.brand)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 32)

                VStack(spacing: 14) {
                    Button {
                        Task { await runSignIn() }
                    } label: {
                        Group {
                            if isSigningIn {
                                ProgressView()
                                    .tint(SignInGatePalette.ctaLabel)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Sign in or sign up")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 14)
                        .background(SignInGatePalette.brand)
                        .foregroundStyle(SignInGatePalette.ctaLabel)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isSigningIn)
                    .padding(.horizontal, 24)

                    Button("Skip for now (testing)") {
                        skippedSignInGate = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(SignInGatePalette.brand.opacity(0.85))
                    .disabled(isSigningIn)
                }
                .padding(.bottom, 36)

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity)
            .background(SignInGatePalette.canvas.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(SignInGatePalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
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
