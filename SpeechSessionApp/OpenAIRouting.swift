import Foundation

/// Chat completions endpoint + async `Authorization` header (BYOK or refreshed Kinde access token).
struct OpenAIChatTransport: Sendable {
    let chatCompletionsURL: URL
    let healthProcessingURL: URL?
    private let authorizationHeader: @Sendable () async throws -> String

    init(chatCompletionsURL: URL, healthProcessingURL: URL? = nil,
         authorizationHeader: @escaping @Sendable () async throws -> String) {
        self.chatCompletionsURL = chatCompletionsURL
        self.healthProcessingURL = healthProcessingURL
        self.authorizationHeader = authorizationHeader
    }

    static func direct(apiKey: String) -> Self {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            preconditionFailure("OpenAI chat URL")
        }
        let key = apiKey
        return Self(chatCompletionsURL: url) { "Bearer \(key)" }
    }

    static func kindeProxy(chatURL: URL, accessToken: @escaping @Sendable () async throws -> String) -> Self {
        let v1 = chatURL.deletingLastPathComponent().deletingLastPathComponent()
        return Self(chatCompletionsURL: chatURL,
                    healthProcessingURL: v1.appendingPathComponent("health-processing/stages"),
                    authorizationHeader: accessToken)
    }

    func makeAuthorizationHeader() async throws -> String {
        try await authorizationHeader()
    }
}
