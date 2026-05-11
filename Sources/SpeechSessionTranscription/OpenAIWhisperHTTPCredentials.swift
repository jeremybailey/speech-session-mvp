import Foundation

/// OpenAI-compatible `v1/audio/transcriptions` call (direct API or proxy). Authorization is resolved when the request runs so Kinde tokens can refresh.
public struct OpenAIWhisperHTTPCredentials: Sendable {
    public let endpointURL: URL
    private let authorizationHeader: @Sendable () async throws -> String

    public init(endpointURL: URL, authorizationHeader: @escaping @Sendable () async throws -> String) {
        self.endpointURL = endpointURL
        self.authorizationHeader = authorizationHeader
    }

    /// Direct OpenAI with API key.
    public static func openAI(apiKey: String) -> Self {
        let key = apiKey
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            preconditionFailure("Invalid OpenAI transcriptions URL")
        }
        return Self(endpointURL: url) { "Bearer \(key)" }
    }

    public func makeAuthorizationHeader() async throws -> String {
        try await authorizationHeader()
    }
}
