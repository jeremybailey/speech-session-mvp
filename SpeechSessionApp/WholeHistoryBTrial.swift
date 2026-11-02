import SwiftUI
import CryptoKit
import SpeechSessionPersistence

// Whole-history processing engine. Source linkage is validated locally; it is not independent clinical verification.
struct BTrialFailure: LocalizedError {
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }
}
struct BTrialFact: Identifiable {
    let id: String, text: String, category: String, status: String, by: String, event: String
    let groups: [String], quotes: [String]
    let plan: [String: String]?
}
struct BTrialConcern: Identifiable {
    let id: String; let name: String; let systems: [String]
    var areas: [HealthAreaKind] {
        let mapped = systems.compactMap { code -> HealthAreaKind? in
            switch code {
            case "musculoskeletal": return .movement
            case "eye": return .eye
            case "neurological": return .neurological
            case "cardiovascular": return .cardiovascular
            case "respiratory": return .respiratory
            case "digestive": return .digestive
            case "endocrine": return .endocrine
            case "reproductive": return .reproductive
            case "urinary": return .urinary
            case "mental": return .mental
            case "skin": return .skin
            case "immune": return .immune
            case "ear": return .ear
            default: return nil
            }
        }
        let unique = mapped.reduce(into: [HealthAreaKind]()) { result, area in if !result.contains(area) { result.append(area) } }
        return unique.isEmpty ? [.other] : unique
    }
}
struct BTrialArea: Identifiable {
    let id: HealthAreaKind
    var concerns: [BTrialConcern]
    static func group(_ concerns: [BTrialConcern]) -> [Self] {
        var result: [Self] = []
        for concern in concerns {
            for area in concern.areas {
                if let index = result.firstIndex(where: { $0.id == area }) { result[index].concerns.append(concern) }
                else { result.append(Self(id: area, concerns: [concern])) }
            }
        }
        return result.enumerated().sorted { lhs, rhs in
            if lhs.element.concerns.count != rhs.element.concerns.count {
                return lhs.element.concerns.count > rhs.element.concerns.count
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

@MainActor final class BTrialModel: ObservableObject {
    @Published var records: [Session] = []
    @Published var selected = Set<UUID>()
    @Published var state = "Ready"
    @Published var error: String?
    @Published var busy = false
    @Published var facts: [BTrialFact] = []
    @Published var concerns: [BTrialConcern] = []
    @Published var overview: [String] = []
    @Published var elapsed: Double?
    @Published var cost: Double?
    @Published var narrativeCoverage: [String: String] = [:]
    @Published var narrative: String?
    @Published var narrativeState = "Not started"
    @Published var narrativeCost: Double?
    @Published var narrativeElapsed: Double?
    private var narrativeJob: [String: Any] { saved["narrativeJob"] as? [String: Any] ?? [:] }
    var narrativeTerminal: Bool { ["completed", "incomplete", "uncertain", "cancelled", "failed", "invalid"].contains(narrativeState) }
    var canReviseOverview: Bool { !busy && (!hasNarrativeJob || narrativeTerminal) && narrativeJob["writerVersion"] as? String != "b-narrative-compact-v6" }
    var hasNarrativeJob: Bool { narrativeJob["run"] != nil }
    private var saved: [String: Any] = [:]
    private var config: [String: Any] = [:]
    private var transport: OpenAIChatTransport?
    private var storageRoot: URL?
    private var loaded = false
    private var accessReady = false
    var hasRun: Bool { saved["run"] != nil }
    var terminal: Bool { ["completed", "incomplete", "uncertain", "cancelled", "failed", "invalid"].contains(state) }
    var configured: Bool { transport?.durableJobsURL != nil || (config["url"] is String && config["token"] is String) }
    var expiry: String { (config["expires"] as? String) ?? "Unavailable" }
    var bodyAreas: [BTrialArea] { BTrialArea.group(concerns) }
    var plans: [BTrialFact] { facts.filter { $0.plan != nil } }
    private var file: URL {
        get throws {
            let root = try (storageRoot ?? SessionStore.makeDefaultStorageDirectory()).appendingPathComponent("whole-history", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var directory = root; try directory.setResourceValues(values)
            return root.appendingPathComponent("preview.json")
        }
    }
    func load(store: SessionStore) async {
        storageRoot = await store.storageDirectory
        do {
            records = try await store.loadAll().filter { !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.processingState != .failed && $0.processingState != .transcribing }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
            selected = Set(records.map(\.id))
            guard !loaded else { return }; loaded = true
            let destination = try file
            let legacy = storageRoot!.appendingPathComponent("experiments/whole-history-b/preview.json")
            if !FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: legacy.path) {
                try Data(contentsOf: legacy).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            if let data = try? Data(contentsOf: file), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                saved = value; state = saved["state"] as? String ?? "queued"
                if let raw = saved["output"] as? String { try decode(raw) }
                elapsed = saved["elapsed"] as? Double; cost = saved["cost"] as? Double
                narrativeState = narrativeJob["state"] as? String ?? "Not started"
                narrativeCost = narrativeJob["cost"] as? Double; narrativeElapsed = narrativeJob["elapsed"] as? Double
                if let raw = narrativeJob["output"] as? String { try decodeNarrative(raw) }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func persist() throws {
        saved["state"] = state
        try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func request(_ action: String, extras: [String: Any] = [:], narrativePass: Bool = false) async throws -> [String: Any] {
        let context = narrativePass ? narrativeJob : saved
        let connection = context["connection"] as? [String: Any] ?? (config["previousConnection"] as? [String: Any]) ?? config
        let url: URL, authorization: String
        guard let run = context["run"] as? String else { throw BTrialFailure(message: "The saved processing identity is missing.") }
        if context["authenticated"] as? Bool == true {
            guard let transport, let jobs = transport.durableJobsURL else { throw BTrialFailure(message: "Sign in to update your health story.") }
            url = jobs.deletingLastPathComponent().appendingPathComponent("whole-history")
            authorization = try await transport.makeAuthorizationHeader()
        } else {
            // Resume only an already-submitted diagnostic job with its original connection.
            guard let raw = connection["url"] as? String, let legacyURL = URL(string: raw), legacyURL.scheme == "https", let token = connection["token"] as? String else { throw BTrialFailure(message: "This older processing request cannot be resumed in this build.") }
            url = legacyURL; authorization = "Bearer " + token
        }
        if context["authenticated"] as? Bool != true, !accessReady, let access = connection["deploymentAccess"] as? String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "_vercel_share", value: access)]
            var handshake = URLRequest(url: components.url!); handshake.timeoutInterval = 30
            let (_, response) = try await URLSession.shared.data(for: handshake)
            guard response.url?.host == url.host, !(HTTPCookieStorage.shared.cookies(for: url) ?? []).isEmpty else {
                throw BTrialFailure(message: "Could not open this private test deployment. Its access may have expired.")
            }
            accessReady = true
        }
        var body = extras; body["action"] = action; body["run"] = run
        if let id = context["id"] { body["id"] = id }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = action == "run" ? 305 : 30
        req.setValue(authorization, forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BTrialFailure(message: "The trial service returned an unreadable response. Resume this same run to check its status.") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { accessReady = false }
            let code = value["error"] as? String ?? "trial_unavailable"
            let messages = ["trial_expired_or_unauthorized": "This private phone trial has expired. A refreshed test deployment is needed.", "too_many_passages": "The selection is larger than this single-request trial supports. Select fewer records.", "context_limit_exceeded": "These records exceed the single-request context allowance. Select fewer records.", "experiment_budget_exhausted": "The experiment's cumulative $5 allowance has no room for this request.", "budget_exhausted": "The shared pilot budget cannot reserve this request.", "overview_context_limit": "These B results exceed the dedicated overview input allowance. Nothing was truncated or submitted.", "invalid_proposal": "The B proposal could not be used for the overview. Your existing preview is retained.", "invalid_overview_focus": "Select up to 12 existing concerns as the overview focus."]
            throw BTrialFailure(message: messages[code] ?? "Trial service: \(code). No automatic paid retry was made.", code: code)
        }
        return value
    }
    func start() async {
        guard !busy, !hasRun, configured, !selected.isEmpty else { return }
        let date = ISO8601DateFormatter()
        let originals: [[String: Any]] = records.filter { selected.contains($0.id) }.map { session in
            let text = session.transcript
            return ["id": session.id.uuidString, "text": text, "date": date.string(from: session.date),
                    "title": session.sourceAssets?.first?.displayName ?? "Saved record", "sourceReference": "local-record:" + session.id.uuidString,
                    "sourceSHA256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()]
        }
        accessReady = false
        saved = ["run": UUID().uuidString.lowercased(), "records": originals, "started": Date().timeIntervalSince1970, "authenticated": true, "contractVersion": "compact-actions-short-overview-v1", "automaticNarrative": true, "serverOverview": true]
        state = "queued"
        do { try persist(); await resume() } catch { self.error = error.localizedDescription }
    }
    func resume() async {
        guard hasRun, !busy, !terminal else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if saved["id"] == nil {
                let result = try await request("prepare", extras: ["records": saved["records"] ?? [], "serverOverview": saved["serverOverview"] as? Bool ?? false])
                guard let id = result["id"] as? String, let locators = result["locators"] as? [String: Any] else { throw BTrialFailure(message: "The trial submission did not return a recoverable identity.") }
                saved["id"] = id; saved["locators"] = locators; saved["contractVersion"] = result["version"]; state = result["state"] as? String ?? "queued"; try persist()
            }
            var response = try await request(saved["stopRequested"] as? Bool == true ? "cancel" : "job")
            if response["state"] as? String == "queued" {
                // This always operates on the persisted job ID; never submits another model job.
                do { response = try await request("run") }
                catch { try Task.checkCancellation(); response = try await request("job") }
            }
            let deadline = Date().addingTimeInterval(360)
            while ["queued", "running"].contains(response["state"] as? String ?? "") {
                state = response["state"] as? String ?? "running"; try persist()
                guard Date() < deadline else { throw BTrialFailure(message: "Still waiting for the same request. Tap Resume to check it; no new paid request will be submitted.") }
                try await Task.sleep(nanoseconds: 2_000_000_000); response = try await request("job")
            }
            state = response["state"] as? String ?? "uncertain"
            if let start = response["started_at"] as? String, let finish = response["finished_at"] as? String {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let s = f.date(from: start), let e = f.date(from: finish) { elapsed = e.timeIntervalSince(s); saved["elapsed"] = elapsed }
            }
            if let nanos = response["cost_nusd"] as? String, let value = Double(nanos) { cost = value / 1e9; saved["cost"] = cost }
            if state == "completed", let result = response["result"] as? [String: Any], let raw = result["output"] as? String {
                do { try decode(raw) } catch {
                    state = "invalid"; try persist(); _ = try? await request("forget"); throw error
                }
                saved["output"] = raw
                if let childID = result["overviewJobID"] as? String, !hasNarrativeJob {
                    saved["narrativeJob"] = ["run": childID, "id": childID, "authenticated": true, "state": "queued", "writerVersion": "b-narrative-compact-v6"]
                    narrativeState = "queued"
                }
                try persist()
                // Save the validated local preview before deleting this run's remote payload.
                _ = try? await request("forget")
                if saved["automaticNarrative"] as? Bool == true {
                    busy = false
                    await writeOverview()
                }
            } else {
                try persist()
                error = state == "uncertain" ? "The provider outcome is uncertain. Its reservation remains held. No automatic paid retry was made." : "Processing stopped (\(state)). Saved records are unchanged."
            }
        } catch {
            if saved["id"] == nil, let failure = error as? BTrialFailure,
               ["invalid_records", "source_hash_mismatch", "too_many_passages", "context_limit_exceeded", "experiment_budget_exhausted", "budget_exhausted"].contains(failure.code ?? "") {
                // These explicit admission rejections happen before a job/reservation
                // can be created. Unknown transport outcomes keep their run identity.
                saved = [:]; state = "Ready"; try? FileManager.default.removeItem(at: file)
            }
            self.error = error.localizedDescription
        }
    }
    func stop() async {
        guard hasRun else { return }
        saved["stopRequested"] = true; try? persist()
        guard saved["id"] != nil else { error = "Stop requested. The same submission will be cancelled when its receipt arrives."; return }
        do { let response = try await request("cancel"); state = response["state"] as? String ?? "uncertain"; try persist() }
        catch { self.error = "Could not confirm Stop. Resume this same run to check its state." }
    }
    func discard() async {
        guard !busy, terminal, !hasNarrativeJob || narrativeTerminal else { return }
        if saved["id"] != nil { accessReady = false; _ = try? await request("forget") }
        if narrativeJob["id"] != nil { accessReady = false; _ = try? await request("forget", narrativePass: true) }
        do { try FileManager.default.removeItem(at: file); saved = [:]; accessReady = false; state = "Ready"; facts = []; concerns = []; overview = []; error = nil; elapsed = nil; cost = nil; narrative = nil; narrativeCoverage = [:]; narrativeState = "Not started"; narrativeCost = nil; narrativeElapsed = nil }
        catch { self.error = error.localizedDescription }
    }
    func rewriteOverview(force: Bool = false) async {
        guard !busy, (!hasNarrativeJob || narrativeTerminal), (force || canReviseOverview) else { return }
        if hasNarrativeJob {
            var history = saved["narrativeHistory"] as? [[String: Any]] ?? []
            history.append(narrativeJob); saved["narrativeHistory"] = history
            saved.removeValue(forKey: "narrativeJob")
        }
        narrativeState = "Not started"; narrativeCost = nil; narrativeElapsed = nil
        do { try persist(); await writeOverview() } catch { self.error = error.localizedDescription }
    }
    // Separate identity and connection preserve existing B jobs and survive app interruption.
    func writeOverview() async {
        guard !busy, state == "completed", !facts.isEmpty, !narrativeTerminal else { return }
        busy = true; error = nil; accessReady = false
        defer { busy = false }
        do {
            if !hasNarrativeJob {
                saved["narrativeJob"] = ["run": UUID().uuidString.lowercased(), "authenticated": true, "state": "queued", "writerVersion": "b-narrative-compact-v6"]
                narrativeState = "queued"; try persist()
            }
            var job = narrativeJob
            if job["id"] == nil {
                guard let raw = saved["output"] as? String,
                      let proposal = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    throw BTrialFailure(message: "No saved B result is available for this writing pass.")
                }
                let receipt = try await request("prepareOverview", extras: ["records": saved["records"] ?? [], "proposal": proposal], narrativePass: true)
                guard let id = receipt["id"] as? String else { throw BTrialFailure(message: "The overview receipt was unreadable. Resume this same request.") }
                job = narrativeJob; job["id"] = id; saved["narrativeJob"] = job; try persist()
            }
            var response = try await request(job["stopRequested"] as? Bool == true ? "cancel" : "job", narrativePass: true)
            if response["state"] as? String == "queued" {
                do { response = try await request("run", narrativePass: true) }
                catch { try Task.checkCancellation(); response = try await request("job", narrativePass: true) }
            }
            let deadline = Date().addingTimeInterval(140)
            while ["queued", "running"].contains(response["state"] as? String ?? "") {
                narrativeState = response["state"] as? String ?? "running"
                job = narrativeJob; job["state"] = narrativeState; saved["narrativeJob"] = job; try persist()
                guard Date() < deadline else { throw BTrialFailure(message: "The overview is still pending. Resume checks the same paid request.") }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                response = try await request("job", narrativePass: true)
            }
            job = narrativeJob; narrativeState = response["state"] as? String ?? "uncertain"; job["state"] = narrativeState
            if let nanos = response["cost_nusd"] as? String, let value = Double(nanos) { narrativeCost = value / 1e9; job["cost"] = narrativeCost }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let start = response["started_at"] as? String, let finish = response["finished_at"] as? String,
               let a = f.date(from: start), let b = f.date(from: finish) { narrativeElapsed = b.timeIntervalSince(a); job["elapsed"] = narrativeElapsed }
            saved["narrativeJob"] = job; try persist()
            if narrativeState == "completed", let result = response["result"] as? [String: Any], let raw = result["output"] as? String {
                // Persist the response before validation, including rejected outputs.
                // Keep clinical diagnostics local; the paid job is never repeated automatically.
                job["output"] = raw; saved["narrativeJob"] = job; try persist()
                do { try decodeNarrative(raw) }
                catch {
                    job["validationIssue"] = (error as? BTrialFailure)?.code ?? "overview_validation_format"
                    job["state"] = "invalid"; narrativeState = "invalid"; saved["narrativeJob"] = job; try persist()
                    _ = try? await request("forget", narrativePass: true)
                    throw error
                }
                job["output"] = raw; saved["narrativeJob"] = job; try persist()
                _ = try? await request("forget", narrativePass: true)
            } else {
                error = "Overview stopped (\(narrativeState)). The original B overview is retained. No automatic paid retry was made."
            }
        } catch {
            if narrativeJob["id"] == nil, let failure = error as? BTrialFailure,
               ["invalid_records", "source_hash_mismatch", "too_many_passages", "context_limit_exceeded", "overview_context_limit", "invalid_proposal", "invalid_overview_focus", "experiment_budget_exhausted", "budget_exhausted"].contains(failure.code ?? "") {
                saved.removeValue(forKey: "narrativeJob"); narrativeState = "Not started"; try? persist()
            }
            self.error = error.localizedDescription
        }
    }
    func stopOverview() async {
        guard hasNarrativeJob, !narrativeTerminal else { return }
        var job = narrativeJob; job["stopRequested"] = true; saved["narrativeJob"] = job; try? persist()
        guard job["id"] != nil else { return }
        do {
            let response = try await request("cancel", narrativePass: true)
            narrativeState = response["state"] as? String ?? "uncertain"
            job = narrativeJob; job["state"] = narrativeState; saved["narrativeJob"] = job; try persist()
        } catch { self.error = "Could not confirm overview cancellation. Resume checks the same request." }
    }
    private func decodeNarrative(_ raw: String) throws {
        func fail(_ reason: String = "format_or_reference") -> BTrialFailure {
            let messages = ["numbers": "The overview included a number that could not be matched to its cited details.", "coverage": "The overview did not consistently account for the conditions in your records.", "sentence_length": "The overview contained a sentence longer than the allowed limit.", "word_limit": "The overview exceeded its 100-word limit.", "character_limit": "The overview exceeded its length limit."]
            return BTrialFailure(message: (messages[reason] ?? "The overview could not be saved because its format or source references were invalid.") + " Your completed details are available. No automatic paid retry was made.", code: "overview_validation_" + reason)
        }
        let compact = narrativeJob["writerVersion"] as? String == "b-narrative-compact-v6"
        let balanced = ["b-narrative-balanced-v3", "b-narrative-balanced-luna-v4", "b-narrative-balanced-v5", "b-narrative-compact-v6"].contains(narrativeJob["writerVersion"] as? String ?? "")
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) } catch { throw fail() }
        guard let obj = parsed as? [String: Any], Set(obj.keys) == (balanced ? ["sentences", "coverage"] : ["sentences"]),
              let sentences = obj["sentences"] as? [[String: Any]], (1...(balanced ? 8 : 6)).contains(sentences.count) else { throw fail() }
        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        func numbers(_ text: String) -> Set<String> {
            let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z])\d+(?:[.,]\d+)?(?:%|mg|mcg|ml|weeks?|days?|years?)?"#, options: [.caseInsensitive])
            return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]).lowercased().replacingOccurrences(of: ",", with: "") } })
        }
        var texts: [String] = []; var cited = Set<String>()
        for sentence in sentences {
            guard Set(sentence.keys) == ["text", "factIDs"], let text = sentence["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= (balanced ? 1200 : 1000),
                  !text.contains("\n"), !text.contains("\r"),
                  text.range(of: #"r\d+\.p\d+\.\d+"#, options: .regularExpression) == nil,
                  let refs = sentence["factIDs"] as? [String], !refs.isEmpty, refs.allSatisfy({ byID[$0] != nil }) else { throw fail() }
            let evidence = refs.compactMap { byID[$0] }.map { fact in
                ([fact.text, fact.by, fact.event] + (fact.plan?.values.map { $0 } ?? [])).joined(separator: " ")
            }.joined(separator: " ")
            guard numbers(text).isSubset(of: numbers(evidence)) else { throw fail("numbers") }
            cited.formUnion(refs); texts.append(text)
        }
        if narrativeJob["writerVersion"] as? String == "b-narrative-focus-v2" {
            for group in narrativeJob["focusIDs"] as? [String] ?? [] {
                guard facts.contains(where: { $0.groups.contains(group) && cited.contains($0.id) }) else { throw fail() }
            }
        }
        var coverage: [String: String] = [:]
        if balanced {
            let codes: Set<String> = ["included_major", "included_secondary", "omitted_minor", "omitted_routine", "omitted_duplicate", "omitted_resolved_without_ongoing_impact", "omitted_uncertain_peripheral"]
            guard let decisions = obj["coverage"] as? [String: String], Set(decisions.keys) == Set(concerns.map(\.id)),
                  decisions.values.allSatisfy({ codes.contains($0) }), decisions.values.contains(where: { $0.hasPrefix("included_") }) else { throw fail("coverage") }
            for (group, decision) in decisions where decision.hasPrefix("included_") {
                guard facts.contains(where: { $0.groups.contains(group) && cited.contains($0.id) }) else { throw fail() }
            }
            if compact || narrativeJob["writerVersion"] as? String == "b-narrative-balanced-v5" {
                let included = Set(decisions.filter { $0.value.hasPrefix("included_") }.keys)
                guard sentences.count <= (compact ? 5 : 6), sentences.allSatisfy({ (($0["text"] as? String)?.count ?? 321) <= (compact ? 260 : 320) }) else { throw fail("sentence_length") }
                for id in cited {
                    guard let fact = byID[id], fact.groups.isEmpty || !Set(fact.groups).isDisjoint(with: included) else { throw fail() }
                }
            }
            coverage = decisions
        }
        let joined = texts.joined(separator: " ")
        guard joined.count <= (compact ? 850 : (balanced ? 1200 : 1000)) else { throw fail("character_limit") }
        guard joined.split(whereSeparator: { $0.isWhitespace }).count <= (compact ? 100 : (balanced ? 150 : 130)) else { throw fail("word_limit") }
        narrative = joined; narrativeCoverage = coverage
    }
    private func decode(_ raw: String) throws {
        func fail() -> BTrialFailure { BTrialFailure(message: "B returned an invalid or unsupported reference structure. The result remains unverified and was not added to your records.") }
        guard let data = raw.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(result.keys) == ["concerns", "overview", "passages"],
              let locators = saved["locators"] as? [String: [String: Any]], let originals = saved["records"] as? [[String: Any]],
              let groups = result["concerns"] as? [[String: Any]], !groups.isEmpty,
              let passages = result["passages"] as? [String: Any], Set(passages.keys) == Set(locators.keys),
              let paragraphs = result["overview"] as? [[String: Any]], (1...6).contains(paragraphs.count) else { throw fail() }
        guard Set(originals.compactMap { $0["id"] as? String }).count == originals.count else { throw fail() }
        if saved["contractVersion"] as? String == "compact-actions-short-overview-v1" {
            guard paragraphs.count == 1, let text = paragraphs[0]["text"] as? String,
                  text.unicodeScalars.count <= 1000, !text.contains("\n"), !text.contains("\r") else { throw fail() }
        }
        let sourceRecords = Dictionary(uniqueKeysWithValues: originals.compactMap { r -> (String, [String: Any])? in guard let id = r["id"] as? String else { return nil }; return (id,r) })
        for locator in locators.values {
            guard let id = locator["recordID"] as? String, let record = sourceRecords[id], let text = record["text"] as? String, let quote = locator["quote"] as? String,
                  let start = locator["start"] as? Int, let end = locator["end"] as? Int, start >= 0, end >= start else { throw fail() }
            let chars = Array(text.unicodeScalars)
            guard end <= chars.count, String(String.UnicodeScalarView(chars[start..<end])) == quote,
                  locator["sourceSHA256"] as? String == SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined() else { throw fail() }
        }
        let categories = Set(SummaryEntryCategory.allCases.map(\.rawValue))
        let systems = Set(["musculoskeletal","eye","neurological","cardiovascular","respiratory","digestive","endocrine","reproductive","urinary","mental","skin","immune","ear","unknown"])
        var groupIDs = Set<String>(); var decodedGroups: [BTrialConcern] = []
        for g in groups {
            guard let id = g["id"] as? String, id.first == "c", let index = Int(id.dropFirst()), (1...256).contains(index), groupIDs.insert(id).inserted,
                  let name = g["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let codes = g["systems"] as? [String], codes.allSatisfy({ systems.contains($0) }),
                  let evidence = g["evidence"] as? [String], !evidence.isEmpty, evidence.allSatisfy({ locators[$0] != nil }) else { throw fail() }
            decodedGroups.append(BTrialConcern(id: id, name: name, systems: codes))
        }
        let careStates = Set(["recommended","conditional","planned","prescribed","declined","performed","historical","reported","unclear"])
        let allStates = careStates.union(["negative","observed","resolved"])
        var decoded: [BTrialFact] = []; var clinical = Set<String>()
        for pid in passages.keys.sorted() {
            if let exclusion = passages[pid] as? String { guard ["nonclinical","other_person","unintelligible"].contains(exclusion) else { throw fail() }; continue }
            guard let rows = passages[pid] as? [[String: Any]], !rows.isEmpty, let locator = locators[pid], let rid = locator["recordID"] as? String else { throw fail() }
            clinical.insert(pid)
            for (index, row) in rows.enumerated() {
                guard Set(row.keys) == ["k","s","v","c","p","g"], let k = row["k"] as? String, categories.contains(k), let status = row["s"] as? String, allStates.contains(status),
                      let v = row["v"] as? [String], v.count == 3, !v[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, v[0].unicodeScalars.count <= 360,
                      let c = row["c"] as? [String], c.count <= 2, c.allSatisfy({ locators[$0]?["recordID"] as? String == rid }),
                      let g = row["g"] as? [String], Set(g).count == g.count, g.allSatisfy({ groupIDs.contains($0) }) else { throw fail() }
                let plan = row["p"] as? [String: String]
                var category = k
                if let plan {
                    guard Set(plan.keys) == ["a","t","q"], (plan["a"] ?? "").range(of: #"^r\d+\.p\d+(\.\d+)?$"#, options: .regularExpression) == nil else { throw fail() }
                    if ["planned","recommended","conditional","prescribed"].contains(status) {
                        if k == "testsAndLabs" { category = "carePlan" }
                        if k == "practitionerContact" { category = "followUp" }
                    }
                    guard ["carePlan","followUp","vaccinations"].contains(category) || (k == "medications" && ["prescribed","recommended","conditional","planned"].contains(status)) else { throw fail() }
                } else if !(row["p"] is NSNull) { throw fail() }
                if ["carePlan","followUp"].contains(category) { guard plan != nil, careStates.contains(status) else { throw fail() } }
                let refs = Array(Set([pid] + c)).sorted()
                decoded.append(BTrialFact(id: "\(pid).\(index+1)", text: v[0], category: category, status: status, by: v[1], event: v[2], groups: g,
                    quotes: refs.compactMap { ref in guard let quote = locators[ref]?["quote"] as? String else { return nil }; return ref + "\n" + quote }, plan: plan))
            }
        }
        guard decodedGroups.allSatisfy({ group in decoded.contains { $0.groups.contains(group.id) } }) else { throw fail() }
        var texts: [String] = []
        for p in paragraphs {
            guard let text = p["text"] as? String, !text.isEmpty, let refs = p["cite"] as? [String], !refs.isEmpty, refs.allSatisfy({ locators[$0] != nil }), refs.contains(where: { clinical.contains($0) }) else { throw fail() }
            texts.append(text)
        }
        facts = decoded; concerns = decodedGroups; overview = texts

    }
}

extension BTrialModel {
    var sourcesMatch: Bool {
        guard let originals = saved["records"] as? [[String: Any]], originals.count == records.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.transcript) })
        return originals.allSatisfy { original in
            guard let rawID = original["id"] as? String, let id = UUID(uuidString: rawID), let text = original["text"] as? String else { return false }
            return byID[id] == text
        }
    }
    func configure(_ transport: OpenAIChatTransport) { self.transport = transport }
    func process(force: Bool = false, overviewOnly: Bool = false) async throws {
        guard !busy else { return }
        error = nil
        if hasRun && !sourcesMatch && (!terminal || (hasNarrativeJob && !narrativeTerminal)) {
            throw BTrialFailure(message: "A previous update is unfinished. Resume or stop it before processing changed records.")
        }
        if !sourcesMatch || (force && terminal) {
            guard !hasRun || (terminal && (!hasNarrativeJob || narrativeTerminal)) else {
                throw BTrialFailure(message: "The previous request is still pending. Resume checks the same request.")
            }
            // Retain the old result for recovery without retaining expired credentials.
            if hasRun {
                var archive = saved; archive.removeValue(forKey: "connection")
                let path = try file.deletingLastPathComponent().appendingPathComponent("previous-result.json")
                try JSONSerialization.data(withJSONObject: archive).write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            saved = [:]; state = "Ready"; facts = []; concerns = []; narrative = nil; narrativeState = "Not started"
            selected = Set(records.map(\.id))
        }
        if !hasRun { await start() }
        else if !terminal { await resume() }
        else if state == "completed", overviewOnly {
            if narrativeTerminal, narrativeState != "completed" || saved["publishedNarrativeRun"] as? String == narrativeJob["run"] as? String { await rewriteOverview(force: true) }
            else if !narrativeTerminal { await writeOverview() }
        }
        else if state == "completed", !narrativeTerminal { await writeOverview() }
        if let error { throw BTrialFailure(message: error) }
        guard state == "completed", narrativeState == "completed", narrative != nil, sourcesMatch else {
            throw BTrialFailure(message: "Updating stopped (\(state), overview \(narrativeState)). Your previous saved story is retained. No automatic paid retry was made.")
        }
    }
    func markPublished() throws {
        if narrativeState == "completed", narrative != nil { saved["publishedNarrativeRun"] = narrativeJob["run"] }
        // Completed diagnostic connections are no longer needed after migration.
        if terminal { saved.removeValue(forKey: "connection") }
        if narrativeTerminal { var job = narrativeJob; job.removeValue(forKey: "connection"); saved["narrativeJob"] = job }
        try persist()
    }
    func publication(allowMissingOverview: Bool = false) throws -> WholeHistoryPublication {
        guard sourcesMatch, state == "completed", (allowMissingOverview || (narrativeState == "completed" && narrative != nil)),
              let locators = saved["locators"] as? [String: [String: Any]] else {
            throw BTrialFailure(message: "The completed result does not match the current original records.")
        }
        func stableID(_ value: String) -> UUID {
            let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
            return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let groupByID = Dictionary(uniqueKeysWithValues: concerns.map { ($0.id, $0) })
        let topics = concerns.flatMap { concern in (concern.systems.isEmpty ? ["unknown"] : concern.systems).map { system in
            HealthTopic(id: stableID("b-topic:" + concern.name.lowercased() + ":" + system), name: concern.name, bodySystem: system)
        } }
        var entries = Dictionary(uniqueKeysWithValues: records.map { ($0.id, [SummaryEntry]()) })
        for fact in facts {
            let pid = fact.id.split(separator: ".").dropLast().joined(separator: ".")
            guard let locator = locators[pid], let rid = locator["recordID"] as? String, let recordID = UUID(uuidString: rid), let record = byID[recordID],
                  let quote = locator["quote"] as? String, let category = SummaryEntryCategory(rawValue: fact.category) else {
                throw BTrialFailure(message: "A result has lost its source record reference.")
            }
            let quotations = fact.quotes.compactMap { $0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) }
            guard !quotations.isEmpty, quotations.allSatisfy({ !$0.isEmpty && record.transcript.contains($0) }) else { throw BTrialFailure(message: "A source quotation no longer matches its original.") }
            let identity = stableID(rid + ":" + String(describing: locator["start"] ?? "") + ":" + fact.category + ":" + fact.text + ":" + fact.by + ":" + fact.event)
            var entry = SummaryEntry(id: identity, category: category, title: fact.text,
                details: (["Recorded status: " + fact.status] + (fact.by.isEmpty ? [] : ["Attribution: " + fact.by]) + (fact.event.isEmpty ? [] : ["Recorded date: " + fact.event]) + (fact.plan?["q"].flatMap { $0.isEmpty ? nil : "Qualifier: " + $0 }.map { [$0] } ?? [])).joined(separator: "\n"),
                sourceSessionID: record.id, sourceTitle: record.displayTitle, sourceDate: record.date, sourceExcerpt: quote,
                provenance: "Whole-history processing · source linked", needsReview: true,
                reviewReason: "Source linked; not independently checked.",
                clinicalStatus: ["historical", "performed", "resolved", "declined"].contains(fact.status) ? .past : .current,
                factKey: "b:" + identity.uuidString)
            var evidence = ClinicalEvidence()
            evidence.assessmentMethod = WholeHistoryPublication.version
            evidence.excerpt = quote; evidence.eventDate = fact.event.isEmpty ? nil : fact.event
            evidence.practitioner = fact.by.isEmpty ? nil : fact.by
            evidence.topicNames = fact.groups.compactMap { groupByID[$0]?.name }
            evidence.wholeHistoryTopicIDs = fact.groups.compactMap { groupByID[$0] }.flatMap { concern in
                (concern.systems.isEmpty ? ["unknown"] : concern.systems).map { stableID("b-topic:" + concern.name.lowercased() + ":" + $0) }
            }
            evidence.conditionSynthesisUnassigned = fact.groups.isEmpty
            evidence.bodySystem = fact.groups.compactMap { groupByID[$0]?.systems.first }.first
            evidence.statusExplicit = ["historical", "performed", "resolved", "declined"].contains(fact.status)
            evidence.factIdentity = "b:" + identity.uuidString
            evidence.reviewReason = "Source linked; not independently checked. Recorded status: " + fact.status
            if let plan = fact.plan {
                var instruction = CareInstruction(instruction: fact.text, schedule: plan["t"].flatMap { $0.isEmpty ? nil : $0 })
                instruction.owner = plan["a"].flatMap { $0.isEmpty ? nil : $0 }
                instruction.consideration = plan["q"].flatMap { $0.isEmpty ? nil : $0 }
                instruction.bucket = ["conditional", "unclear", "declined", "performed", "historical", "resolved", "reported"].contains(fact.status) ? .considerations : (category == .followUp ? .followUp : .carePlan)
                evidence.careInstruction = instruction
                evidence.actionKind = ["performed", "historical", "resolved"].contains(fact.status) ? "treatment_received" : (category == .followUp ? "follow_up" : "homecare")
            }
            entry.evidence = evidence
            let contentHash = SummaryVerification.contentHash(entry)
            entry.evidence?.assessment = SummaryAssessment(admission: .sourceLinked, reason: "Exact source quotations validated locally; no independent model check.", sourceHash: SummaryVerification.hash(record.transcript), contentHash: contentHash, citations: quotations.map { SummaryCitation(field: "detail", excerpt: $0) })
            entries[record.id, default: []].append(entry)
        }
        return WholeHistoryPublication(entries: entries, topics: topics, overview: narrativeState == "completed" ? narrative : nil)
    }
}

struct WholeHistoryBTrialView: View {
    let store: SessionStore
    @StateObject private var model = BTrialModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            Section {
                Text("Whole-history B · experimental").font(.headline)
                Text("B organizes copies of selected saved text, then a separate writing pass creates a short overview. Results stay in this unverified preview; your saved details and care plans are unchanged.")
                Text("The 20-record benchmark took 3m49s. Phone time depends on the records and connection.").font(.footnote).foregroundStyle(.secondary)
            }
            if !model.configured { Text("This build has no active phone-trial configuration.") }
            else {
                Section("Trial") {
                    Text("State: \(model.state)")
                    Text("Access expires: \(model.expiry)").font(.caption)
                    if let elapsed = model.elapsed { LabeledContent("Server processing", value: String(format: "%.0f seconds", elapsed)) }
                    if let cost = model.cost { LabeledContent("Estimated API cost", value: String(format: "$%.5f USD", cost)) }
                    if !model.hasRun {
                        Button("Run B on \(model.selected.count) records") { Task { await model.start() } }.disabled(model.selected.isEmpty)
                    } else if !model.terminal {
                        if model.busy { ProgressView("Processing the same request…") }
                        Button("Resume this run") { Task { await model.resume() } }.disabled(model.busy)
                        Button("Stop this run", role: .destructive) { Task { await model.stop() } }
                    }
                    if model.terminal && (!model.hasNarrativeJob || model.narrativeTerminal) { Button("Discard this preview", role: .destructive) { Task { await model.discard() } }.disabled(model.busy) }
                }
                if !model.hasRun {
                    Section("Records · saved source text only") {
                        Button(model.selected.count == model.records.count ? "Deselect all" : "Select all") { model.selected = model.selected.count == model.records.count ? [] : Set(model.records.map(\.id)) }
                        ForEach(model.records) { r in
                            Toggle(isOn: Binding(get: { model.selected.contains(r.id) }, set: { if $0 { model.selected.insert(r.id) } else { model.selected.remove(r.id) } })) {
                                VStack(alignment: .leading) { Text(r.sourceAssets?.first?.displayName ?? r.date.formatted(date: .abbreviated, time: .shortened)); Text(r.transcript.prefix(90)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            if let error = model.error { Section("Status") { Text(error).foregroundStyle(.red) } }
            if !model.facts.isEmpty {
                Section("Unverified result") {
                    Text("\(model.facts.count) details · \(model.concerns.count) concerns · \(model.plans.count) action occurrences")
                    NavigationLink("All details") { BTrialFactsView(facts: model.facts).navigationTitle("B details") }
                    NavigationLink("Care-plan occurrences") { BTrialFactsView(facts: model.plans).navigationTitle("B care plans") }
                    NavigationLink("Conditions by body system") {
                        BTrialBodySystemsView(areas: model.bodyAreas, facts: model.facts)
                    }
                }
                Section("Two-pass overview · unverified") {
                    Text("Uses B’s existing details and condition links. The writer weighs major history, lasting effects and ongoing care across all concerns. This does not independently verify them.").font(.footnote)
                    Text("State: \(model.narrativeState)").font(.caption)
                    if let text = model.narrative { Text(text).textSelection(.enabled) }
                    if let elapsed = model.narrativeElapsed { LabeledContent("Writing pass", value: String(format: "%.0f seconds", elapsed)) }
                    if let cost = model.narrativeCost { LabeledContent("Writing cost", value: String(format: "$%.5f USD", cost)) }
                    if model.canReviseOverview {
                        Button("Write revised overview") { Task { await model.rewriteOverview() } }
                    }
                    if !model.narrativeCoverage.isEmpty {
                        DisclosureGroup("Topics included and left out") {
                            ForEach(model.concerns) { concern in
                                VStack(alignment: .leading) {
                                    Text(concern.name)
                                    Text((model.narrativeCoverage[concern.id] ?? "").replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if model.hasNarrativeJob && !model.narrativeTerminal {
                        Button(model.hasNarrativeJob ? "Resume overview writing" : "Write improved overview") { Task { await model.writeOverview() } }.disabled(model.busy)
                        if model.busy { ProgressView("Writing a short overview…") }
                        if model.hasNarrativeJob { Button("Stop overview writing", role: .destructive) { Task { await model.stopOverview() } } }
                    }
                }
                Section("Conditions · by body system · unverified") {
                    BTrialBodySystemRows(areas: model.bodyAreas, facts: model.facts)
                }
                Section("Original B overview · unverified") { ForEach(Array(model.overview.enumerated()), id: \.offset) { _, text in Text(text) } }
            }
        }
        .navigationTitle("Whole-history B trial")
        .task { await model.load(store: store) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.resume(); if model.hasNarrativeJob && !model.narrativeTerminal { await model.writeOverview() } } } }
    }
}
struct BTrialFactsView: View {
    let facts: [BTrialFact]
    var body: some View {
        List(facts) { fact in
            VStack(alignment: .leading, spacing: 8) {
                Text(fact.text)
                Text("\(fact.category) · \(fact.status) · \(fact.by)").font(.caption).foregroundStyle(.secondary)
                if !fact.event.isEmpty { Text(fact.event).font(.caption) }
                if let p = fact.plan {
                    if let a = p["a"], !a.isEmpty { Text("Responsible: " + a).font(.footnote) }
                    if let t = p["t"], !t.isEmpty { Text("Timing: " + t).font(.footnote) }
                    if let q = p["q"], !q.isEmpty { Text(q).font(.footnote) }
                }
                DisclosureGroup("Original source quotations") { ForEach(Array(fact.quotes.enumerated()), id: \.offset) { _, quote in Text(quote).font(.footnote).textSelection(.enabled) } }
            }.padding(.vertical, 4)
        }
    }
}

struct BTrialBodySystemRows: View {
    let areas: [BTrialArea]
    let facts: [BTrialFact]
    var body: some View {
        ForEach(areas) { area in
            NavigationLink {
                BTrialConditionListView(concerns: area.concerns, facts: facts).navigationTitle(area.id.title)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: area.id.symbol).font(.title2).foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(area.id.title).font(.headline)
                        Text("\(area.concerns.count) concern\(area.concerns.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                        Text(area.concerns.map(\.name).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.padding(.vertical, 4)
            }
        }
        let unassigned = facts.filter { $0.groups.isEmpty }
        if !unassigned.isEmpty {
            NavigationLink("Details without a condition (\(unassigned.count))") {
                BTrialFactsView(facts: unassigned).navigationTitle("Other B details")
            }
        }
    }
}
struct BTrialBodySystemsView: View {
    let areas: [BTrialArea]
    let facts: [BTrialFact]
    var body: some View {
        List {
            Section {
                Text("B’s saved condition labels, grouped for navigation. These are unverified proposals. A concern can appear in more than one body system; sharing a system does not establish a clinical relationship.").font(.footnote).foregroundStyle(.secondary)
            }
            Section { BTrialBodySystemRows(areas: areas, facts: facts) }
        }.navigationTitle("B body systems")
    }
}
struct BTrialConditionListView: View {
    let concerns: [BTrialConcern]
    let facts: [BTrialFact]
    var body: some View {
        List(concerns) { concern in
            let linked = facts.filter { $0.groups.contains(concern.id) }
            NavigationLink {
                BTrialFactsView(facts: linked).navigationTitle(concern.name)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(concern.name)
                    Text("\(linked.count) linked detail\(linked.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
