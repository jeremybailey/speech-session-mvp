import Foundation

/// Explicit Stop is separate from cancellation of foreground polling.
actor DurableProcessingStop {
    private var stopped = false
    private var actions: [UUID: @Sendable () async throws -> Void] = [:]
    func register(_ action: @escaping @Sendable () async throws -> Void) throws -> UUID {
        guard !stopped else { throw CancellationError() }
        let id = UUID()
        actions[id] = action
        return id
    }
    func completed(_ id: UUID) { actions.removeValue(forKey: id) }
    func stop() async throws {
        stopped = true
        var failed = false
        let pending = Array(actions.values)
        for action in pending {
            do { try await action() } catch { failed = true }
        }
        if failed { throw URLError(.cannotConnectToHost) }
        actions.removeAll()
    }
}

/// Chat completions endpoint + async `Authorization` header (BYOK or refreshed Kinde access token).
struct OpenAIChatTransport: Sendable {
    let chatCompletionsURL: URL
    let healthProcessingURL: URL?
    private let authorizationHeader: @Sendable () async throws -> String
    var explicitStop: DurableProcessingStop?

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

    /// Build-time pilot gate; never fall back to unbudgeted inference from this route.
    var durableJobsURL: URL? {
        guard Bundle.main.object(forInfoDictionaryKey: "DurableAIProcessingEnabled") as? Bool == true,
              let healthProcessingURL else { return nil }
        return healthProcessingURL.deletingLastPathComponent().appendingPathComponent("jobs")
    }

    var durableConditionWorkflowsURL: URL? {
        guard Bundle.main.object(forInfoDictionaryKey: "DurableConditionWorkflowsEnabled") as? Bool == true,
              let durableJobsURL else { return nil }
        return durableJobsURL.deletingLastPathComponent().appendingPathComponent("condition-workflows")
    }

    func durableRequest(payload: [String: Any], conditionWorkflow: Bool = false) async throws -> String {
        guard let url = conditionWorkflow ? durableConditionWorkflowsURL : durableJobsURL else { throw URLError(.unsupportedURL) }
        struct Job: Decodable {
            struct Result: Decodable { let output: String }
            let id: String
            let state: String
            let result: Result?
        }
        func exchange(_ url: URL, method: String, body: Data? = nil) async throws -> Job {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try await makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validateDurableResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            return try JSONDecoder().decode(Job.self, from: data)
        }
        // Server hashes canonical content, ignoring transient request IDs. Re-submission is safe.
        let body = try JSONSerialization.data(withJSONObject: payload)
        let authorize = authorizationHeader
        let stopID = try await explicitStop?.register {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try await authorize(), forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        let submitted = try await exchange(url, method: "POST", body: body)
        var statusURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        statusURL.queryItems = [URLQueryItem(name: "id", value: submitted.id)]
        // Submission may deduplicate to an already completed job, but only GET
        // includes its result. Never mistake that small POST response for expiry.
        var job = try await exchange(statusURL.url!, method: "GET")
        while true {
            try Task.checkCancellation()
            switch job.state {
            case "completed":
                if let stopID { await explicitStop?.completed(stopID) }
                guard let result = job.result else {
                    throw NSError(domain: "AIProcessing", code: 410, userInfo: [NSLocalizedDescriptionKey: "This processing result has expired. It will not be automatically charged again."])
                }
                NotificationCenter.default.post(name: Notification.Name("AIProcessingCompleted"), object: nil)
                return result.output
            case "queued", "running":
                try await Task.sleep(for: .seconds(3))
                job = try await exchange(statusURL.url!, method: "GET")
            default:
                if let stopID { await explicitStop?.completed(stopID) }
                NotificationCenter.default.post(name: Notification.Name("AIProcessingCompleted"), object: nil)
                throw NSError(domain: "AIProcessing", code: 409, userInfo: [NSLocalizedDescriptionKey: "Processing stopped (\(job.state)). Check AI usage in Settings. No automatic paid retry was made."])
            }
        }
    }

    static func validateDurableResponse(data: Data, status: Int) throws {
        guard !(200..<300).contains(status) else { return }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (body?["error"] as? [String: Any])?["code"] as? String
        let message: String
        switch status {
        case 401, 403: message = "Please sign in again in Settings to continue secure processing. Your saved records are unchanged."
        case 402: message = "The processing budget has been reached. Check AI usage in Settings; retrying will not increase the allowance."
        case 404, 405: message = "This app and the processing service need matching updates. Your saved records are unchanged; retrying will not fix this."
        case 400, 413: message = "The processing service could not accept this request. Your saved records are unchanged. Please contact support before retrying."
        default: message = code == "pilot_disabled"
            ? "Budgeted processing is not enabled on the server yet. Your saved records are unchanged."
            : "Budgeted processing could not connect. Your saved records are unchanged; a submitted job may still finish in the background."
        }
        // Never surface raw provider errors, source excerpts, or credentials.
        throw NSError(domain: "AIProcessing", code: status, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
