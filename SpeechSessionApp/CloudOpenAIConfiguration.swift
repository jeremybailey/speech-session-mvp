import Foundation

/// Reads the Vercel proxy base URL from the app Info.plist (`CloudOpenAIBaseURL`).
/// Value should include the `/api` path prefix, e.g. `https://your-app.vercel.app/api`
enum CloudOpenAIConfiguration {
    static var proxyBaseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CloudOpenAIBaseURL") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var url = URL(string: trimmed)
        if url?.hasDirectoryPath == false, !trimmed.hasSuffix("/") {
            url = URL(string: trimmed + "/")
        }
        return url
    }

    /// `…/api` + `v1/chat/completions`
    static func chatCompletionsURL() -> URL? {
        guard let base = proxyBaseURL else { return nil }
        return base.appendingPathComponent("v1/chat/completions")
    }

    /// `…/api` + `v1/audio/transcriptions`
    static func audioTranscriptionsURL() -> URL? {
        guard let base = proxyBaseURL else { return nil }
        return base.appendingPathComponent("v1/audio/transcriptions")
    }

    static var hasProxy: Bool { proxyBaseURL != nil }
}
