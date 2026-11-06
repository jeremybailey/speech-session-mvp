import SwiftUI
import CryptoKit
import SpeechSessionPersistence

// Whole-history processing engine. Source linkage is validated locally; it is not independent clinical verification.
struct BTrialFailure: LocalizedError {
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }
}
typealias BTrialFact = WholeHistoryDecodedFact
typealias BTrialConcern = WholeHistoryDecodedConcern
extension WholeHistoryDecodedConcern {
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
    var canReviseOverview: Bool { !busy && (!hasNarrativeJob || narrativeTerminal) && narrativeJob["writerVersion"] as? String != "b-narrative-brief-v7" }
    var hasNarrativeJob: Bool { narrativeJob["run"] != nil }
    private var saved: [String: Any] = [:]
    private var onOverviewStarted: (() -> Void)?
    private var config: [String: Any] = [:]
    private var transport: OpenAIChatTransport?
    private var storageRoot: URL?
    private var loaded = false
    private var accessReady = false
    var usesCategoryObjectV7: Bool { state == "completed" && saved["contractVersion"] as? String == "structured-artifact-objects-v7" }
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
                if let raw = narrativeJob["output"] as? String {
                    try decodeNarrative(raw)
                    // Re-run all current reference, number and coverage checks before recovering a saved rejection.
                    if narrativeState == "invalid", ["overview_validation_word_limit","overview_validation_format_or_reference"].contains(narrativeJob["validationIssue"] as? String ?? "") {
                        var job = narrativeJob; job["state"] = "completed"; job.removeValue(forKey: "validationIssue")
                        saved["narrativeJob"] = job; narrativeState = "completed"; try persist()
                    }
                }
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
        saved = ["run": UUID().uuidString.lowercased(), "records": originals, "started": Date().timeIntervalSince1970, "authenticated": true, "contractVersion": "compact-actions-short-overview-v1", "automaticNarrative": true, "serverOverview": true, "structuredMedications": true, "structuredArtifacts": true, "aggregatePlans": true, "briefPlans": true, "careTitles": true, "strictArtifacts": true, "categorySemantics": true, "balancedCategories": true, "uniformFields": true, "eligibleFacts": true]
        state = "queued"
        do { try persist(); await resume() } catch { self.error = error.localizedDescription }
    }
    func resume(recheckFailure: Bool = false, revalidateSavedDetails: Bool = false) async {
        guard hasRun, !busy, (!terminal || (recheckFailure && state == "failed")) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if saved["id"] == nil {
                let result = try await request("prepare", extras: ["records": saved["records"] ?? [], "eligibleFacts": saved["eligibleFacts"] as? Bool ?? false, "serverOverview": saved["serverOverview"] as? Bool ?? false, "structuredMedications": saved["structuredMedications"] as? Bool ?? false, "structuredArtifacts": saved["structuredArtifacts"] as? Bool ?? false, "aggregatePlans": saved["aggregatePlans"] as? Bool ?? false, "briefPlans": saved["briefPlans"] as? Bool ?? false, "careTitles": saved["careTitles"] as? Bool ?? false, "strictArtifacts": saved["strictArtifacts"] as? Bool ?? false, "categorySemantics": saved["categorySemantics"] as? Bool ?? false, "balancedCategories": saved["balancedCategories"] as? Bool ?? false, "uniformFields": saved["uniformFields"] as? Bool ?? false])
                guard let id = result["id"] as? String, let locators = result["locators"] as? [String: Any] else { throw BTrialFailure(message: "The trial submission did not return a recoverable identity.") }
                saved["id"] = id; saved["locators"] = locators; saved["contractVersion"] = result["version"]; state = result["state"] as? String ?? "queued"; try persist()
            }
            var response = try await request(saved["stopRequested"] as? Bool == true ? "cancel" : "job")
            if revalidateSavedDetails, response["state"] as? String == "failed",
               (response["result"] as? [String:Any])?["overview_error"] as? String == "invalid_proposal" {
                response = try await request("run", extras:["revalidateSavedDetails":true])
                saved["revalidationRejected"] = response["state"] as? String == "failed"
                saved["revalidationRevision"] = "sole-evidence-link-v2"
                try persist()
            }
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
                    state = "invalid"
                    saved["validationFailure"] = (error as? BTrialFailure)?.code ?? "details_validation"
                    try persist()
                    throw error
                }
                saved.removeValue(forKey:"failureCode")
                saved["output"] = raw
                if let childID = result["overviewJobID"] as? String, !hasNarrativeJob {
                    saved["narrativeJob"] = ["run": childID, "id": childID, "authenticated": true, "state": "queued", "writerVersion": saved["eligibleFacts"] as? Bool == true ? "b-narrative-visible-v8" : ["structured-plans-brief-v5","structured-care-titles-v6","structured-artifact-objects-v7","category-semantics-v8","category-contract-v9","category-balanced-v14","category-uniform-fields-v18","category-uniform-fields-scoped-v19"].contains(saved["contractVersion"] as? String ?? "") ? "b-narrative-brief-v7":"b-narrative-compact-v6"]
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
                let failureCode=(response["result"] as? [String:Any])?["overview_error"] as? String
                saved["failureCode"]=failureCode;try persist()
                if failureCode == "invalid_proposal" {
                    error = canRevalidateSavedDetails ? "The generated details need a format check before the overview can start. Recheck saved result checks the existing response without repeating the full update. Your saved records are unchanged." : "The generated details still do not meet the required format. Your saved records are unchanged. Start a new update to generate a replacement."
                } else if failureCode == "budget_exhausted" {
                    error="The details finished, but the overview could not reserve its budget. Your saved story is unchanged. No automatic paid retry was made."
                } else { error = state == "uncertain" ? "The provider outcome is uncertain. Its reservation remains held. No automatic paid retry was made." : "Processing stopped (\(state)). Saved records are unchanged." }
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
        onOverviewStarted?()
        busy = true; error = nil; accessReady = false
        defer { busy = false }
        do {
            if !hasNarrativeJob {
                saved["narrativeJob"] = ["run": UUID().uuidString.lowercased(), "authenticated": true, "state": "queued", "writerVersion": "b-narrative-visible-v8", "briefOverview": true, "eligibleFacts": true]
                narrativeState = "queued"; try persist()
            }
            var job = narrativeJob
            if job["id"] == nil {
                guard let raw = saved["output"] as? String,
                      let proposal = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    throw BTrialFailure(message: "No saved B result is available for this writing pass.")
                }
                let receipt = try await request("prepareOverview", extras: ["records": saved["records"] ?? [], "proposal": proposal, "eligibleFacts": narrativeJob["eligibleFacts"] as? Bool ?? false, "briefOverview": narrativeJob["briefOverview"] as? Bool ?? false], narrativePass: true)
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
            let messages = ["numbers": "The overview included a number that could not be matched to its cited details.", "coverage": "The overview did not consistently account for the conditions in your records.", "sentence_length": "The overview contained a sentence longer than the allowed limit.", "word_limit": "The overview exceeded its display length limit.", "character_limit": "The overview exceeded its length limit."]
            return BTrialFailure(message: (messages[reason] ?? "The overview could not be saved because its format or source references were invalid.") + " Your completed details are available. No automatic paid retry was made.", code: "overview_validation_" + reason)
        }
        do {
            let result=try WholeHistoryNarrativeContract.decode(raw,facts:facts,concerns:concerns,writerVersion:narrativeJob["writerVersion"] as? String,focusIDs:narrativeJob["focusIDs"] as? [String] ?? [])
            narrative=result.text;narrativeCoverage=result.coverage
        } catch let issue as WholeHistoryNarrativeContract.Failure {throw fail(issue.reason)}
    }

    private func decode(_ raw: String) throws {
        do {
            let decoded = try WholeHistoryResponseContract.decode(
                raw, locators: saved["locators"] as? [String: [String: Any]],
                originals: saved["records"] as? [[String: Any]],
                version: saved["contractVersion"] as? String
            )
            facts = decoded.facts; concerns = decoded.concerns; overview = decoded.overview
        } catch let failure as WholeHistoryResponseContract.Failure {
            throw BTrialFailure(message: failure.localizedDescription, code: failure.code)
        }
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
    var canRevalidateSavedDetails: Bool {
        state == "failed" && saved["failureCode"] as? String == "invalid_proposal" && (saved["revalidationRejected"] as? Bool != true || saved["revalidationRevision"] as? String != "sole-evidence-link-v2")
    }
    var requiresNewAttempt: Bool {
        WholeHistoryRecoveryPolicy.requiresNewAttempt(
            generationTerminal: terminal, generationCompleted: state == "completed",
            overviewTerminal: narrativeTerminal, overviewCompleted: narrativeState == "completed",
            retainedRecords: retainedPublishedRecordCount,
            canRevalidateSavedDetails: canRevalidateSavedDetails
        )
    }

    #if DEBUG
    var recoveryDiagnostic: [String: Any] {
        [
            "generation": state,
            "validationFailure": saved["validationFailure"] as? String ?? "",
            "overview": narrativeState,
            "sourcesMatch": sourcesMatch,
            "hasUnpublishedResult": hasUnpublishedCompletedResult,
            "retainedRecords": retainedPublishedRecordCount
        ]
    }
    #endif

    func configure(_ transport: OpenAIChatTransport) { self.transport = transport }
    func process(force: Bool = false, overviewOnly: Bool = false, revalidateSavedDetails: Bool = false, onOverviewStarted: (() -> Void)? = nil) async throws {
        guard !busy else { throw BTrialFailure(message: "An update is already running. View progress to check it.") }
        self.onOverviewStarted = onOverviewStarted
        defer { self.onOverviewStarted = nil }
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
        else if !terminal || state == "failed" { await resume(recheckFailure: true,revalidateSavedDetails:revalidateSavedDetails) }
        else if state == "completed", overviewOnly {
            if narrativeTerminal, narrativeState != "completed" || saved["publishedNarrativeRun"] as? String == narrativeJob["run"] as? String { await rewriteOverview(force: true) }
            else if !narrativeTerminal { await writeOverview() }
        }
        else if state == "completed", !narrativeTerminal { await writeOverview() }
        if let error { throw BTrialFailure(message: error) }
        guard state == "completed", narrativeState == "completed", narrative != nil, sourcesMatch else {
            throw BTrialFailure(message: "Some details couldn’t be added. Your saved records are available.")
        }
    }
    var hasUnpublishedCompletedResult: Bool {
        guard sourcesMatch, state == "completed", narrativeState == "completed", narrative != nil,
              let run = narrativeJob["run"] as? String else { return false }
        return retainedPublishedRecordCount == 0 && saved["publishedNarrativeRun"] as? String != run
    }

    var retainedPublishedRecordCount: Int { sourcesMatch ? (saved["retainedPublishedRecordCount"] as? Int ?? 0) : 0 }

    func markPublished(retainedRecordCount: Int = 0) throws {
        saved["retainedPublishedRecordCount"] = retainedRecordCount
        if retainedRecordCount == 0, narrativeState == "completed", narrative != nil { saved["publishedNarrativeRun"] = narrativeJob["run"] }
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
                fields: fact.fields ?? [], sourceSessionID: record.id, sourceTitle: record.displayTitle, sourceDate: record.date, sourceExcerpt: quote,
                provenance: "Whole-history processing · source linked", needsReview: true,
                reviewReason: "Source linked; not independently checked.",
                clinicalStatus: ["historical", "performed", "resolved", "declined"].contains(fact.status) ? .past : .current,
                factKey: "b:" + identity.uuidString)
            var evidence = ClinicalEvidence()
            evidence.assessmentMethod = WholeHistoryPublication.version
            evidence.excerpt = quote; evidence.eventDate = fact.event.isEmpty ? nil : fact.event
            evidence.sourceAttribution = fact.by.isEmpty ? nil : fact.by
            evidence.practitioner = BClinicalPresentation.namedPractitioner(fact.by)
            evidence.medication = fact.medication
            evidence.artifactSchema = fact.fields == nil ? nil : StructuredArtifact.version
            evidence.topicNames = fact.groups.compactMap { groupByID[$0]?.name }
            evidence.wholeHistoryTopicIDs = fact.groups.compactMap { groupByID[$0] }.flatMap { concern in
                (concern.systems.isEmpty ? ["unknown"] : concern.systems).map { stableID("b-topic:" + concern.name.lowercased() + ":" + $0) }
            }
            evidence.conditionSynthesisUnassigned = fact.groups.isEmpty
            evidence.bodySystem = fact.groups.compactMap { groupByID[$0]?.systems.first }.first
            evidence.statusExplicit = category != .medications && ["historical", "performed", "resolved", "declined"].contains(fact.status)
            evidence.factIdentity = "b:" + identity.uuidString
            evidence.reviewReason = "Source linked; not independently checked. Recorded status: " + fact.status
            if let plan = fact.plan {
                var instruction = CareInstruction(instruction: fact.text, schedule: plan["t"].flatMap { $0.isEmpty ? nil : $0 })
                instruction.recordStatus = fact.status
                instruction.planID = plan["i"]
                instruction.planTitle = plan["h"].flatMap{$0.isEmpty ? nil:$0}
                instruction.isConcise = plan["i"] == nil ? nil:true
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


/// Rollout gate: keep installed legacy receipts readable while the new path passes release gates.
@MainActor enum IncrementalRecordCoordinator {
    private enum RecoveryError: Error { case expired }
    static var enabled: Bool { (Bundle.main.object(forInfoDictionaryKey:"IncrementalRecordsEnabled") as? Bool == true) || (Bundle.main.object(forInfoDictionaryKey:"IncrementalRecordsEnabled") as? String == "YES") }
    static func request(_ action:String,receipt:RecordUpdateReceipt,records:[Session],transport:OpenAIChatTransport,snapshot:[String:Any]? = nil) async throws -> [String:Any] {
        guard let jobs=transport.durableJobsURL else {throw URLError(.unsupportedURL)}
        var request=URLRequest(url:jobs.deletingLastPathComponent().appendingPathComponent("record-updates"))
        request.httpMethod="POST";request.timeoutInterval=30
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue(try await transport.makeAuthorizationHeader(),forHTTPHeaderField:"Authorization")
        var body:[String:Any]=["id":receipt.id.uuidString.lowercased(),"action":action]
        if let snapshot {body["snapshot"]=snapshot}
        if action == "prepare" || action == "prepareOverview" {
            body["records"]=records.map {["id":$0.id.uuidString.lowercased(),"text":$0.transcript]}
            if let url=Bundle.main.url(forResource:"ReleaseManifest",withExtension:"json"),let data=try? Data(contentsOf:url) {
                body["release"]=try JSONSerialization.jsonObject(with:data)
            } else {throw URLError(.cannotDecodeContentData)}
        }
        request.httpBody=try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)
        let (data,response)=try await DurableNetworkRecovery.run {try await URLSession.shared.data(for:request)}
        if (response as? HTTPURLResponse)?.statusCode == 410 {throw RecoveryError.expired}
        try OpenAIChatTransport.validateDurableResponse(data:data,status:(response as? HTTPURLResponse)?.statusCode ?? 0)
        guard let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw URLError(.cannotParseResponse)}
        return result
    }
    static func writeOverview(store:SessionStore,transport:OpenAIChatTransport,facts:[HealthFact],allowExpiredReplacement:Bool = true,allowFailedReplacement:Bool = false) async throws {
        guard !facts.isEmpty else {return}
        if await store.storyOverview(for:facts) != nil {return}
        let context=await store.currentOverviewConditionContext(facts)
        let fingerprint=IncrementalRecordUpdate.sourceHash(StoryOverview.fingerprint(facts)+context)
        var receipt=try await store.recordOverviewReceipt()
        if receipt?.sources["snapshot"] != fingerprint || receipt?.state == "cancelled" {
            receipt=RecordUpdateReceipt(sources:["snapshot":fingerprint])
            try await store.saveRecordOverviewReceipt(receipt!)
        }
        guard let current=receipt else {return}
        let snapshot:[String:Any]=["fingerprint":fingerprint,"conditionContext":context,"facts":facts.sorted {$0.id<$1.id}.map {fact in
            let entry=fact.displayEntry
            return ["id":fact.id,"text":([entry.title,entry.details,"Status: "+(fact.hasKnownStatus ? fact.statusTitle:"Unknown")]+entry.fields.map {$0.label+": "+$0.value}).joined(separator:"\n")]
        }]
        let stopID=try await transport.explicitStop?.register {
            var stopped=current;stopped.state="cancelled";try await store.saveRecordOverviewReceipt(stopped)
            _=try await request("cancel",receipt:current,records:[],transport:transport)
        }
        defer {if let stopID {Task {await transport.explicitStop?.completed(stopID)}}}
        var status:[String:Any]
        do {status=try await request("prepareOverview",receipt:current,records:[],transport:transport,snapshot:snapshot)}
        catch RecoveryError.expired where allowExpiredReplacement {
            try await store.saveRecordOverviewReceipt(RecordUpdateReceipt(sources:current.sources))
            try await writeOverview(store:store,transport:transport,facts:facts,allowExpiredReplacement:false)
            return
        }
        while true {
            try Task.checkCancellation()
            guard status["contract"] as? String == IncrementalRecordUpdate.version else {throw URLError(.cannotParseResponse)}
            if let result=(status["units"] as? [[String:Any]])?.first?["result"] as? [String:Any],let overview=result["overview"] {
                let narrative=try JSONDecoder().decode(StoryOverview.self,from:JSONSerialization.data(withJSONObject:overview))
                try await store.saveStoryOverview(narrative,expected:facts)
                var completed=current;completed.state="completed";try await store.saveRecordOverviewReceipt(completed)
                return
            }
            if let state=status["state"] as? String,["completed_with_withheld_items","blocked","cancelled"].contains(state) {
                var failed=current;failed.state=state;try await store.saveRecordOverviewReceipt(failed)
                if state == "cancelled" {throw CancellationError()}
                // Only an explicit patient retry may replace a terminal overview.
                // Keep the previous server receipt/accounting; never restart records.
                if IncrementalRecordUpdate.mayReplaceOverview(state:state,explicitlyRequested:allowFailedReplacement) {
                    try await store.saveRecordOverviewReceipt(RecordUpdateReceipt(sources:current.sources))
                    try await writeOverview(store:store,transport:transport,facts:facts,allowExpiredReplacement:false,allowFailedReplacement:false)
                    return
                }
                throw URLError(.cannotParseResponse)
            }
            try await Task.sleep(nanoseconds:3_000_000_000)
            status=try await request("status",receipt:current,records:[],transport:transport)
        }
    }
    static func run(store:SessionStore,transport:OpenAIChatTransport,allowExpiredReplacement:Bool = true,collectSavedResults:Bool = false,onPublication:() async -> Void) async throws -> Bool {
        let all=try await store.loadAll()
        var receipt=try await store.recordUpdateReceipt()
        let terminal:Set<String>=["completed","completed_with_withheld_items","blocked","cancelled"]
        // Explicit retry first collects newly revalidated saved results. It does
        // not reset server attempts or regenerate unchanged source records.
        if collectSavedResults, var previous=receipt,
           ["completed_with_withheld_items","blocked"].contains(previous.state),
           previous.sources.allSatisfy({id,hash in all.contains {$0.id.uuidString==id && IncrementalRecordUpdate.sourceHash($0.transcript)==hash}}),
           try await store.recordsNeedingIncrementalUpdate().isEmpty {
            previous.state="queued"
            try await store.saveRecordUpdateReceipt(previous)
            receipt=previous
        }
        if let previous=receipt,!terminal.contains(previous.state),previous.sources.contains(where:{id,hash in !all.contains(where:{$0.id.uuidString==id && IncrementalRecordUpdate.sourceHash($0.transcript)==hash})}) {
            _=try await request("cancel",receipt:previous,records:[],transport:transport)
            receipt=nil
        }
        if receipt == nil || terminal.contains(receipt!.state) {
            let pending=try await store.recordsNeedingIncrementalUpdate()
            guard !pending.isEmpty else {return false}
            receipt=RecordUpdateReceipt(sources:Dictionary(uniqueKeysWithValues:pending.map {($0.id.uuidString,IncrementalRecordUpdate.sourceHash($0.transcript))}))
            try await store.saveRecordUpdateReceipt(receipt!)
        }
        guard let current=receipt else {return false}
        let records=all.filter {current.sources[$0.id.uuidString] != nil}
        let stopID=try await transport.explicitStop?.register {
            if var stopped=try await store.recordUpdateReceipt(),stopped.id==current.id {
                stopped.state="cancelled"
                try await store.saveRecordUpdateReceipt(stopped)
            }
            _=try await Self.request("cancel",receipt:current,records:[],transport:transport)
        }
        defer {if let stopID {Task {await transport.explicitStop?.completed(stopID)}}}
        var status:[String:Any]
        do {status=try await request("prepare",receipt:current,records:records,transport:transport)}
        catch RecoveryError.expired where allowExpiredReplacement {
            try await store.saveRecordUpdateReceipt(RecordUpdateReceipt(sources:current.sources))
            return try await run(store:store,transport:transport,allowExpiredReplacement:false,onPublication:onPublication)
        }
        while true {
            try Task.checkCancellation()
            guard status["contract"] as? String == IncrementalRecordUpdate.version else {throw URLError(.cannotParseResponse)}
            for unit in status["units"] as? [[String:Any]] ?? [] {
                guard let result=unit["result"] as? [String:Any],let rows=result["facts"],let rid=unit["record_id"] as? String,let recordID=UUID(uuidString:rid),let hash=unit["source_hash"] as? String,let key=unit["unit_key"] as? String else {continue}
                let facts=try JSONDecoder().decode([IncrementalRecordFact].self,from:JSONSerialization.data(withJSONObject:rows))
                try await store.publishRecordUnit(facts,recordID:recordID,sourceHash:hash,unitKey:key,updateID:current.id)
            }
            await onPublication()
            guard status["contract"] as? String == IncrementalRecordUpdate.version else {throw URLError(.cannotParseResponse)}
            let state=status["state"] as? String ?? "running"
            if terminal.contains(state) {
                if state == "cancelled" {throw CancellationError()}
                try await store.finishRecordUpdate(current.id,state:state)
                return state != "completed"
            }
            try await Task.sleep(nanoseconds:3_000_000_000)
            status=try await request("status",receipt:current,records:[],transport:transport)
        }
    }
}
