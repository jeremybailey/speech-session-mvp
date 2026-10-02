import Foundation
import CryptoKit

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

    func durableRequest(payload: [String: Any], conditionWorkflow: Bool = false,
                        transferProgress: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        guard let url = conditionWorkflow ? durableConditionWorkflowsURL : durableJobsURL else { throw URLError(.unsupportedURL) }
        struct Job: Decodable {
            struct Result: Decodable { let output: String?; let chunkCount: Int?; let digest: String?; let chunk: String? }
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
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let chunked = conditionWorkflow && body.count > 350_000
        let chunkSize = 240_000
        let chunkCount = (body.count + chunkSize - 1) / chunkSize
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let uploadIdentity: [String: Any] = ["digest": digest, "count": chunkCount]
        func upload(_ operation: String, index: Int? = nil) async throws -> [String: Any] {
            var value = uploadIdentity
            value["operation"] = operation
            if let index {
                value["index"] = index
                value["content"] = body.subdata(in: (index * chunkSize)..<min(body.count, (index + 1) * chunkSize)).base64EncodedString()
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try await makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validateDurableResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        let authorize = authorizationHeader
        let stopID = try await explicitStop?.register {
            var request = URLRequest(url: url)
            request.httpMethod = chunked ? "PUT" : "DELETE"
            if chunked {
                var stop = uploadIdentity; stop["operation"] = "cancel"
                request.httpBody = try JSONSerialization.data(withJSONObject: stop)
            } else { request.httpBody = body }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try await authorize(), forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        let submitted: Job
        if chunked {
            await transferProgress?("Checking saved upload progress…")
            var status = try await upload("status")
            if status["state"] as? String == "uploading" {
                let received = Set(status["received"] as? [Int] ?? [])
                for index in 0..<chunkCount where !received.contains(index) {
                    try Task.checkCancellation()
                    await transferProgress?("Uploading saved details \(index + 1) of \(chunkCount)… Keep the app open until upload finishes.")
                    let part = try await upload("part", index: index)
                    if part["state"] as? String == "cancelled" { throw CancellationError() }
                }
                try Task.checkCancellation()
                status = try await upload("finish")
            }
            guard status["id"] is String else {
                throw NSError(domain: "AIProcessing", code: 409, userInfo: [NSLocalizedDescriptionKey:
                    "History upload stopped (\(status["state"] as? String ?? "unavailable")). Saved records are unchanged; no new processing was started."])
            }
            submitted = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: status))
        } else { submitted = try await exchange(url, method: "POST", body: body) }
        if conditionWorkflow { await transferProgress?("Organizing securely in the background…") }
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
                if let output = result.output { return output }
                if conditionWorkflow, let count = result.chunkCount, (1...1000).contains(count), let digest = result.digest {
                    var assembled = Data()
                    for index in 0..<count {
                        try Task.checkCancellation()
                        var partURL = statusURL
                        partURL.queryItems?.append(URLQueryItem(name: "part", value: String(index)))
                        let part = try await exchange(partURL.url!, method: "GET")
                        guard let encoded = part.result?.chunk, let bytes = Data(base64Encoded: encoded), bytes.count <= 240_000 else { throw URLError(.cannotDecodeContentData) }
                        assembled.append(bytes)
                    }
                    guard SHA256.hash(data: assembled).map({ String(format: "%02x", $0) }).joined() == digest,
                          let output = String(data: assembled, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                    return output
                }
                throw URLError(.cannotDecodeContentData)
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
