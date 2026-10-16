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

/// Bounds foreground waiting only. It never cancels or resubmits a paid job.
struct DurableProcessingWait {
    let startedAt: Date
    let timeout: TimeInterval
    init(conditionWorkflow: Bool, now: Date = Date()) {
        startedAt = now
        timeout = conditionWorkflow ? 30 * 60 : 5 * 60
    }
    func check(state: String, now: Date = Date()) throws {
        guard ["queued", "running"].contains(state), now.timeIntervalSince(startedAt) >= timeout else { return }
        throw NSError(domain: "AIProcessing", code: 408, userInfo: [NSLocalizedDescriptionKey:
            "The processing service has not returned a result within the waiting limit. Your saved records are unchanged. The submitted request may still finish in the background; no new paid request was started. Contact support if this keeps happening."])
    }
}

/// Version the content before either direct submission or chunked-upload hashing.
/// Repeating the same repaired request stays idempotent, including explicit Stop.
enum DurableRequestIdentity {
    static func body(_ payload: [String: Any], conditionWorkflow: Bool) throws -> Data {
        var value = payload
        if conditionWorkflow { value["clientRevision"] = "condition-exact-heading-v2" }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

/// A durable local copy must exist before the server is allowed to purge a result.
/// Kept with local history, excluded from device backup, and pruned after seven days.
struct DurableResultReceipt: Codable {
    let jobID: String
    let output: String
    let expiresAt: Date

    /// Older deployments have no receipt endpoint. Keep the durable local copy
    /// for a later acknowledgment, but do not misreport successful inference as
    /// a clinical processing failure. Other errors remain explicit failures.
    static func validateAcknowledgment(data: Data, status: Int, jobID: String) throws -> Bool {
        if status == 405 { return false }
        try OpenAIChatTransport.validateDurableResponse(data: data, status: status)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["received"] as? Bool == true, result["id"] as? String == jobID else {
            throw URLError(.cannotDecodeContentData)
        }
        return true
    }

    static func directory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw URLError(.cannotCreateFile)
        }
        return support.appendingPathComponent("SpeechSessions/cloud-result-receipts", isDirectory: true)
    }

    static func key(body: Data, url: URL, authorization: String, experimental: Bool) throws -> String {
        // Scope local results to the account, never to a token that changes on refresh.
        // The server independently verifies the JWT; these claims only isolate local files.
        let parts = authorization.replacingOccurrences(of: "Bearer ", with: "").split(separator: ".")
        guard parts.count == 3 else { throw URLError(.userAuthenticationRequired) }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let issuer = claims["iss"] as? String, !issuer.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var identity = try JSONSerialization.data(withJSONObject: [issuer, subject, url.absoluteString, experimental ? "experiment" : "release"])
        identity.append(body)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    static func load(key: String, directory: URL? = nil) throws -> Self? {
        let root = try directory ?? Self.directory()
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if let data = try? Data(contentsOf: file), let receipt = try? JSONDecoder().decode(Self.self, from: data), receipt.expiresAt <= Date() {
                try FileManager.default.removeItem(at: file)
            }
        }
        let file = root.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func save(key: String, directory: URL? = nil) throws {
        let root = try directory ?? Self.directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var directory = root; try directory.setResourceValues(excluded)
        let data = try JSONEncoder().encode(self)
        #if os(iOS)
        try data.write(to: root.appendingPathComponent(key + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: root.appendingPathComponent(key + ".json"), options: [.atomic])
        #endif
    }
}

/// The checked-facts pipeline is the release default; explicit experiments retain their sub-budget.
enum FastDetailsConfiguration {
    static var enabled: Bool { ProcessInfo.processInfo.environment["COLLECTIVECARE_FAST_DETAILS"] != "0" }
    static var experimental: Bool { ProcessInfo.processInfo.environment["COLLECTIVECARE_FAST_DETAILS"] == "1" }
}

/// Retries only the same HTTP operation/body. Polling never resubmits a job.
enum DurableNetworkRecovery {
    static func run<T>(sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }, _ operation: () async throws -> T) async throws -> T {
        for attempt in 0...2 {
            do { try Task.checkCancellation(); return try await operation() }
            catch {
                try Task.checkCancellation()
                let code = (error as? URLError)?.code
                guard attempt < 2, let code,
                      [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(code) else { throw error }
                try await sleep(UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        throw URLError(.cannotConnectToHost)
    }
}

/// Chat completions endpoint + async `Authorization` header (BYOK or refreshed Kinde access token).
struct OpenAIChatTransport: Sendable {
    let chatCompletionsURL: URL
    let healthProcessingURL: URL?
    private let authorizationHeader: @Sendable () async throws -> String
    var fastExperiment = false
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

    func fastDetailsTransport(experimental: Bool = FastDetailsConfiguration.experimental) throws -> Self {
        guard healthProcessingURL != nil else { throw URLError(.userAuthenticationRequired) }
        var result = self
        result.fastExperiment = experimental
        return result
    }

    func applyExperimentHeader(to request: inout URLRequest) {
        if fastExperiment { request.setValue("fast-details", forHTTPHeaderField: "X-CollectiveCare-Pipeline") }
    }

    func fastDetailsCapacity() async throws -> Int {
        guard let jobs = durableJobsURL else { throw URLError(.unsupportedURL) }
        var url = URLComponents(url: jobs, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "capacity", value: fastExperiment ? "fast-details" : "checked-details")]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        applyExperimentHeader(to: &request)
        request.setValue(try await makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await DurableNetworkRecovery.run { try await URLSession.shared.data(for: request) }
        try Self.validateDurableResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["pipeline"] as? String == "fast-details-v1", let limit = value["maxInFlight"] as? Int,
              (0...4).contains(limit) else { throw URLError(.cannotDecodeContentData) }
        guard limit > 0 else { throw NSError(domain: "AIProcessing", code: 402, userInfo: [NSLocalizedDescriptionKey: "The experiment has insufficient remaining allowance for one request. No processing was started."]) }
        return limit
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
        let waiting = DurableProcessingWait(conditionWorkflow: conditionWorkflow)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        struct Job: Decodable {
            struct Result: Decodable {
                struct Diagnostics: Decodable { let incompleteReason: String? }
                let output: String?; let chunkCount: Int?; let digest: String?; let chunk: String?
                let diagnostics: Diagnostics?
            }
            let id: String
            let state: String
            let result: Result?
        }
        func exchange(_ url: URL, method: String, body: Data? = nil) async throws -> Job {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyExperimentHeader(to: &request)
            request.setValue(try await makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await DurableNetworkRecovery.run { try await session.data(for: request) }
            do { try Self.validateDurableResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0) }
            catch {
                let ns = error as NSError
                if method == "POST", !conditionWorkflow, ns.domain == "AIProcessing", ns.code == 402 {
                    var info = ns.userInfo; info["reservationRejected"] = true
                    throw NSError(domain: ns.domain, code: ns.code, userInfo: info)
                }
                throw error
            }
            return try JSONDecoder().decode(Job.self, from: data)
        }
        // Server hashes canonical content, ignoring transient request IDs. Re-submission is safe.
        let body = try DurableRequestIdentity.body(payload, conditionWorkflow: conditionWorkflow)
        let receiptKey = try DurableResultReceipt.key(body: body, url: url,
            authorization: try await makeAuthorizationHeader(), experimental: fastExperiment)
        func acknowledge(_ receipt: DurableResultReceipt) async throws -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "id", value: receipt.jobID)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyExperimentHeader(to: &request)
            request.setValue(try await makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
            let digest = SHA256.hash(data: Data(receipt.output.utf8)).map { String(format: "%02x", $0) }.joined()
            request.httpBody = try JSONSerialization.data(withJSONObject: ["digest": digest])
            do {
                let (data, response) = try await DurableNetworkRecovery.run { try await session.data(for: request) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // A false result means legacy endpoint: keep the receipt for a
                // later attempt; existing server expiry remains in effect.
                _ = try DurableResultReceipt.validateAcknowledgment(data: data, status: status, jobID: receipt.jobID)
            } catch {
                throw NSError(domain: "AIProcessingReceipt", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The result is saved on this iPhone, but cloud cleanup has not been confirmed. Retry to confirm cleanup without another AI charge."])
            }
            return receipt.output
        }
        func receive(_ output: String, jobID: String) async throws -> String {
            let receipt = DurableResultReceipt(jobID: jobID, output: output, expiresAt: Date().addingTimeInterval(7 * 24 * 60 * 60))
            try receipt.save(key: receiptKey)
            return try await acknowledge(receipt)
        }
        if let receipt = try DurableResultReceipt.load(key: receiptKey) {
            return try await acknowledge(receipt)
        }
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
            applyExperimentHeader(to: &request)
            request.setValue(try await makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let (data, response) = try await DurableNetworkRecovery.run { try await session.data(for: request) }
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
            applyExperimentHeader(to: &request)
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
                if let output = result.output { return try await receive(output, jobID: job.id) }
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
                    return try await receive(output, jobID: job.id)
                }
                throw URLError(.cannotDecodeContentData)
            case "queued", "running":
                try waiting.check(state: job.state)
                try await Task.sleep(for: .seconds(3))
                job = try await exchange(statusURL.url!, method: "GET")
            default:
                if let stopID { await explicitStop?.completed(stopID) }
                NotificationCenter.default.post(name: Notification.Name("AIProcessingCompleted"), object: nil)
                try Self.validateDurableCompletion(state: job.state, incompleteReason: job.result?.diagnostics?.incompleteReason)
                throw NSError(domain: "AIProcessing", code: 409, userInfo: [NSLocalizedDescriptionKey: "Processing stopped (\(job.state)). Check AI usage in Settings. No automatic paid retry was made."])
            }
        }
    }

    static func validateDurableCompletion(state: String, incompleteReason: String?) throws {
        if state == "incomplete" && incompleteReason == "max_output_tokens" {
            throw NSError(domain: "AIProcessingOutput", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The checking response reached its output limit; the unfinished batch needs a smaller request."])
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
