import Foundation
import KindeSDK
import SpeechSessionTranscription
import SwiftUI

/// Wraps Kinde SDK auth for CollectiveCare (token for OpenAI proxy, sign-in UI).
@MainActor
final class KindeAuthManager: ObservableObject {
    @Published private(set) var isSignedIn = false

    private static var didConfigure = false

    init() {
        Self.configureOnce()
        syncState()
        completeSummaryEngineBootstrapIfSessionRestoredWithoutLogin()
    }

    private static func configureOnce() {
        guard !didConfigure else { return }
        KindeSDKAPI.configure(DefaultLogger(), fileName: "kinde-auth")
        didConfigure = true
    }

    func syncState() {
        isSignedIn = KindeSDKAPI.auth.isAuthenticated()
    }

    /// URLs opened by Kinde / AppAuth after login or logout must not be queued as share-import handoffs.
    static func isKindeOAuthCallbackURL(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare("comcollectivecarepilotkinde") == .orderedSame
    }

    var userPreview: String? {
        KindeSDKAPI.auth.getUserDetails()?.email
    }

    func login() async throws {
        try await KindeSDKAPI.auth.login()
        syncState()
        applyFirstAccountOpenAISummaryDefaultIfNeeded()
    }

    func logout() async {
        _ = await KindeSDKAPI.auth.logout()
        syncState()
    }

    /// Access token for `Authorization: Bearer` on the OpenAI proxy (refreshes if needed).
    func freshAccessToken() async throws -> String {
        try await KindeSDKAPI.auth.getToken()
    }

    func openAIChatTransport(byokFallback rawKey: String) async -> OpenAIChatTransport? {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSignedIn, let url = CloudOpenAIConfiguration.chatCompletionsURL() {
            return OpenAIChatTransport.kindeProxy(chatURL: url) { [weak self] in
                guard let self else { throw KindeAuthError.noAccessToken }
                let t = try await self.freshAccessToken()
                return "Bearer \(t)"
            }
        }
        guard !trimmed.isEmpty else { return nil }
        return OpenAIChatTransport.direct(apiKey: trimmed)
    }

    func openAIWhisperCredentials(byokKey rawKey: String) async -> OpenAIWhisperHTTPCredentials? {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSignedIn, let url = CloudOpenAIConfiguration.audioTranscriptionsURL() {
            return OpenAIWhisperHTTPCredentials(endpointURL: url) { [weak self] in
                guard let self else { throw KindeAuthError.noAccessToken }
                let t = try await self.freshAccessToken()
                return "Bearer \(t)"
            }
        }
        guard !trimmed.isEmpty else { return nil }
        return .openAI(apiKey: trimmed)
    }

    enum KindeAuthError: LocalizedError {
        case noAccessToken

        var errorDescription: String? {
            switch self {
            case .noAccessToken:
                return "Could not obtain an access token. Sign in again."
            }
        }
    }

    /// Once true, we never auto-change summary engine on login (user / restored-session state wins).
    private static let summaryEngineAccountBootstrapCompletedKey = "speechSession.summaryEngineAccountBootstrapCompleted"

    /// Cold start with a persisted Kinde session: respect whatever summary engine is already in AppStorage.
    private func completeSummaryEngineBootstrapIfSessionRestoredWithoutLogin() {
        guard UserDefaults.standard.object(forKey: Self.summaryEngineAccountBootstrapCompletedKey) == nil else { return }
        guard isSignedIn else { return }
        UserDefaults.standard.set(true, forKey: Self.summaryEngineAccountBootstrapCompletedKey)
    }

    /// First successful **interactive** login / sign-up on this install: prefer OpenAI when cloud (or debug BYOK) is ready.
    /// Returning users who open the app already signed in are handled in `completeSummaryEngineBootstrapIfSessionRestoredWithoutLogin`.
    private func applyFirstAccountOpenAISummaryDefaultIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.summaryEngineAccountBootstrapCompletedKey) == nil else { return }
        guard isSignedIn else { return }
        if isCloudSummaryAvailableWhileSignedIn {
            UserDefaults.standard.set("openai", forKey: "speechSession.summaryBackend")
        }
        UserDefaults.standard.set(true, forKey: Self.summaryEngineAccountBootstrapCompletedKey)
    }

    /// Same rule as `SettingsView.cloudInferenceReady` (without SwiftUI).
    private var isCloudSummaryAvailableWhileSignedIn: Bool {
        let signedInWithProxy = isSignedIn && CloudOpenAIConfiguration.hasProxy
        #if DEBUG
        let byokKey = (UserDefaults.standard.string(forKey: "speechSession.openaiAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return signedInWithProxy || !byokKey.isEmpty
        #else
        return signedInWithProxy
        #endif
    }
}
