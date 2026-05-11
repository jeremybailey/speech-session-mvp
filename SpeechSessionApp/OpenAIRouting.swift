import Foundation

/// Chat completions endpoint + async `Authorization` header (BYOK or refreshed Kinde access token).
struct OpenAIChatTransport: Sendable {
    let chatCompletionsURL: URL
    private let authorizationHeader: @Sendable () async throws -> String

    init(chatCompletionsURL: URL, authorizationHeader: @escaping @Sendable () async throws -> String) {
        self.chatCompletionsURL = chatCompletionsURL
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
        Self(chatCompletionsURL: chatURL, authorizationHeader: accessToken)
    }

    func makeAuthorizationHeader() async throws -> String {
        try await authorizationHeader()
    }
}
