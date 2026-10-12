import Foundation

/// Experimental orchestration; it does not change global verification eligibility.
public struct FastDetailsWorkUnit: Codable, Hashable, Sendable {
    public var entries: [SummaryEntry]
    public var checks: [SummaryCheck]?
    public init(entries: [SummaryEntry], checks: [SummaryCheck]? = nil) { self.entries = entries; self.checks = checks }
}
public struct FastDetailsRequest: Sendable {
    public let stage: String
    public let phase: String
    public let instructions: String
    public let input: String
    public let responseFormat: Data
    public init(stage: String, instructions: String, input: String, responseFormat: [String: Any], phase: String? = nil) throws {
        self.stage = stage; self.phase = phase ?? stage; self.instructions = instructions; self.input = input
        self.responseFormat = try JSONSerialization.data(withJSONObject: responseFormat, options: [.sortedKeys])
    }
}

/// One scheduler per processing run, shared by all records and sections. Round-robin
/// record queues prevent a long record from monopolizing permits. Cancellation of
/// a waiter never consumes a slot; auth or exhausted-budget failures close admission.
public actor FastDetailsScheduler {
    public struct Metrics: Codable, Sendable {
        public var operations = 0
        public var queueWaitSeconds = 0.0
        public var operationSeconds = 0.0
        public var peakActive = 0
    }
    public private(set) var metrics = Metrics()
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var limit: Int
    private var active = 0
    private var queues: [UUID: [Waiter]] = [:]
    private var order: [UUID] = []
    private var stopped: Error?
    public var isStopped: Bool { stopped != nil }
    public init(limit: Int = 4) { self.limit = min(4, max(1, limit)) }
    private struct ReservationBackpressure: Error {}
    public func perform<T: Sendable>(group: UUID, operation: @Sendable () async throws -> T) async throws -> T {
        while true {
            do { return try await performAttempt(group: group, operation: operation) }
            catch is ReservationBackpressure { try Task.checkCancellation() }
        }
    }
    private func performAttempt<T: Sendable>(group: UUID, operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID(), queuedAt = ProcessInfo.processInfo.systemUptime
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let stopped { continuation.resume(throwing: stopped); return }
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if queues[group] == nil { queues[group] = []; order.append(group) }
                queues[group]!.append(Waiter(id: id, continuation: continuation)); drain()
            }
        } onCancel: { Task { await self.cancel(id) } }
        let started = ProcessInfo.processInfo.systemUptime
        metrics.queueWaitSeconds += started - queuedAt
        defer { metrics.operationSeconds += ProcessInfo.processInfo.systemUptime - started; active -= 1; drain() }
        do { try Task.checkCancellation(); metrics.operations += 1; return try await operation() }
        catch {
            let ns = error as NSError
            // Only a rejected submission is eligible: no paid job was created.
            // Let existing reservations settle, reduce concurrency, then requeue.
            // A lone rejected request is genuine exhaustion and still stops.
            if ns.domain == "AIProcessing", ns.code == 402,
               ns.userInfo["reservationRejected"] as? Bool == true, active > 1 {
                limit = max(1, limit - 1)
                throw ReservationBackpressure()
            }
            if (ns.domain == "AIProcessing" && [401, 402, 403].contains(ns.code)) ||
                (error as? SummaryResponseError) == .signInRequired || (error as? SummaryResponseError) == .quotaExceeded {
                stopped = error; failWaiters(error)
            }
            throw error
        }
    }
    private func drain() {
        while stopped == nil, active < limit, !order.isEmpty {
            let group = order.removeFirst()
            guard var waiters = queues.removeValue(forKey: group), !waiters.isEmpty else { continue }
            let waiter = waiters.removeFirst()
            if !waiters.isEmpty { queues[group] = waiters; order.append(group) }
            active += 1; metrics.peakActive = max(metrics.peakActive, active); waiter.continuation.resume()
        }
    }
    private func cancel(_ id: UUID) {
        for group in order {
            if let index = queues[group]?.firstIndex(where: { $0.id == id }) {
                let waiter = queues[group]!.remove(at: index)
                if queues[group]!.isEmpty { queues.removeValue(forKey: group); order.removeAll { $0 == group } }
                waiter.continuation.resume(throwing: CancellationError()); return
            }
        }
    }
    private func failWaiters(_ error: Error) {
        let pending = queues.values.flatMap { $0 }; queues = [:]; order = []
        for waiter in pending { waiter.continuation.resume(throwing: error) }
    }
}

public enum FastDetailsCheck {
    /// Locators are derived locally from unchanged source, never accepted as semantic proof.
    static func evidenceTable(_ entries: [SummaryEntry], source: String) -> [String: String] {
        let quotes = Array(Set(entries.compactMap { $0.supportingExcerpt }.compactMap {
            SummaryVerification.matchingCitation($0, source: source)
        })).sorted()
        return Dictionary(uniqueKeysWithValues: quotes.enumerated().map { ("Q\($0.offset)", $0.element) })
    }
    public static func request(_ entries: [SummaryEntry], source: String, repair: Bool = false) throws -> FastDetailsRequest {
        var value = try JSONSerialization.jsonObject(with: Data(SummarySourceCheck.input(entries, source: source).utf8)) as! [String: Any]
        // Candidates help locate evidence, but are neither proof nor verdicts.
        value["candidateEvidence"] = evidenceTable(entries, source: source)
        let instructions = SummarySourceCheck.instructions(count: entries.count) + """

        COMPACT EVIDENCE CONTRACT: citations maps each required field to an array of evidence IDs.
        Use an empty array when a field has no supporting evidence. Reference candidateEvidence IDs
        directly; do not repeat their quotations in the response. The evidence array contains ONLY new
        verbatim original-source quotations as {id,excerpt}, using new IDs prefixed with N.
        candidateEvidence is a locator only: independently read originalSource and confirm context,
        attribution, negation and every claim. Every evidenceID must resolve in candidateEvidence or
        your new evidence array. A quote can support multiple fields only when it supports EACH
        field's meaning. A literal match alone never establishes support. Use exactly the field names
        in fieldsToCheck, including parent careInstruction rather than invented nested field names.
        For supported entries use an empty reason string; explain only unsupported or uncertain judgments.
        Do not invent evidence, weaken claims or change the supplied draft.
        """ + (repair ? "\nThis is the one repair pass. Recheck the complete supplied claims independently; do not assume prior support. Pay attention to missing evidence and statement attribution/type." : "")
        var format = ClinicalResponseFormat.forStage("checking", expectedCheckIDs: entries.map(\.id))
        var schema = format["json_schema"] as! [String: Any]
        var root = schema["schema"] as! [String: Any]
        var properties = root["properties"] as! [String: Any]
        var decisions = properties["decisions"] as! [String: Any]
        var rows = decisions["properties"] as! [String: Any]
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        for entry in entries {
            let id = entry.id.uuidString
            var row = rows[id] as! [String: Any]; var fields = row["properties"] as! [String: Any]
            fields["citations"] = object(Dictionary(uniqueKeysWithValues: SummaryVerification.requiredFields(entry).map {
                ($0, ["type": "array", "items": ["type": "string"]] as [String: Any])
            }))
            fields.removeValue(forKey: "id") // The enclosing key already identifies this decision.
            row["properties"] = fields; row["required"] = fields.keys.sorted(); rows[id] = row
        }
        decisions["properties"] = rows; properties["decisions"] = decisions
        properties["evidence"] = ["type": "array", "items": object(["id": ["type": "string"], "excerpt": ["type": "string"]])]
        root["properties"] = properties; root["required"] = properties.keys.sorted()
        schema["schema"] = root; schema["name"] = "fast_details_compact_check_v2_1"; format["json_schema"] = schema
        return try FastDetailsRequest(stage: "checking", instructions: instructions,
            input: String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self), responseFormat: format, phase: repair ? "repair" : "checking")
    }
    public static func decode(_ raw: String, entries: [SummaryEntry], source: String) throws -> [SummaryCheck] {
        guard let value = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let evidence = value["evidence"] as? [[String: String]],
              var decisions = value["decisions"] as? [String: Any] else { throw SummaryResponseError.invalidFormat }
        var table = evidenceTable(entries, source: source)
        var declared = Set(table.keys)
        let allowed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.uuidString, SummaryVerification.requiredFields($0)) })
        for row in evidence {
            guard let id = row["id"], !id.isEmpty, declared.insert(id).inserted, let excerpt = row["excerpt"] else { throw SummaryResponseError.invalidFormat }
            // An invalid quote supplies no evidence. Preserve other decisions and let
            // the existing field-coverage gate route this claim to targeted repair.
            table[id] = SummaryVerification.matchingCitation(excerpt, source: source)
        }
        for (id, value) in decisions {
            guard var row = value as? [String: Any], let citations = row["citations"] as? [String: [String]],
                  let required = allowed[id], Set(citations.keys) == required else { throw SummaryResponseError.invalidFormat }
            row["id"] = id
            row["citations"] = try citations.keys.sorted().flatMap { field in
                try citations[field]!.compactMap { ref -> [String: String]? in
                    guard declared.contains(ref) else { throw SummaryResponseError.invalidFormat }
                    guard let excerpt = table[ref] else { return nil }
                    return ["field": field, "excerpt": excerpt]
                }
            }
            decisions[id] = row
        }
        return try SummaryResponseError.decodeKeyedChecks(decisions, expectedIDs: entries.map(\.id))
    }
}

public struct FastDetailsPipeline: Sendable {
    public static let version = "fast-details-v2.2"
    public static let sourceLimit = 24_000
    /// Split at a nearby source boundary while retaining every original character.
    static func splitExtraction(_ text: String) -> [String] {
        guard text.count > 1 else { return [text] }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let searchEnd = text.index(middle, offsetBy: max(1, text.count / 4), limitedBy: text.endIndex) ?? text.endIndex
        let window = text[middle..<searchEnd]
        let boundary = window.firstIndex(of: "\n") ?? window.firstIndex(where: { $0.isWhitespace }) ?? middle
        let cut = boundary == middle ? middle : text.index(after: boundary)
        return [String(text[..<cut]), String(text[cut...])]
    }
    public static func extractionSources(_ text: String) -> [String] {
        guard text.count > sourceLimit else { return text.isEmpty ? [] : [text] }
        let halves = splitExtraction(text)
        return halves.flatMap { extractionSources($0) }
    }
    public typealias Send = @Sendable (FastDetailsRequest) async throws -> String
    public typealias Extract = @Sendable (String, Int) async throws -> [SummaryEntry]
    public let scheduler: FastDetailsScheduler
    public init(scheduler: FastDetailsScheduler) { self.scheduler = scheduler }

    public func process(session: Session, sources: [String], store: SessionStore,
                        extract: @escaping Extract, send: @escaping Send,
                        progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        // Completed checked facts are reusable across presentation changes. Inspect the live
        // snapshot, not the caller's potentially stale copy, and never republish over edits.
        if let current = try await store.healthSnapshot().sessions.first(where: { $0.id == session.id }),
           current.transcript == session.transcript,
           current.summaryRun?.stage == .complete,
           current.summaryRun?.sourceHash == SummaryVerification.hash(session.transcript),
           current.summaryRun?.version == SummaryVerification.version,
           current.summaryRun?.promptVersion == Self.version,
           current.summaryEntries != nil { return }
        let run = try await store.beginSummaryRun(sessionID: session.id, expected: session, promptVersion: Self.version)
        do {
            let sections = try await SummaryParallelWork.map(Array(sources.enumerated()), limit: 4) { item in
                let (index, source) = item, prefix = "section:\(index):" + SummaryVerification.hash(source)
                @Sendable func save(_ key: String, _ unit: FastDetailsWorkUnit) async throws {
                    try await store.checkpointSummaryUnit(sessionID: session.id, runID: run.id, key: key, unit: unit)
                }
                @Sendable func cached(_ key: String) async throws -> FastDetailsWorkUnit? {
                    try await store.summaryWorkUnits(sessionID: session.id, runID: run.id)[key]
                }
                @Sendable func extraction(_ text: String, key: String, split: Bool) async throws -> [SummaryEntry] {
                    if let saved = try await cached(key) { return saved.entries }
                    @Sendable func halves() async throws -> [SummaryEntry] {
                        let parts = Self.splitExtraction(text)
                        guard parts.count > 1 else { throw SummaryResponseError.responseTooLong }
                        let values = try await SummaryParallelWork.map(Array(parts.enumerated()), limit: 2) { part in
                            try await extraction(part.element, key: key + "/part:\(part.offset)", split: false)
                        }.flatMap { $0 }
                        try await save(key, FastDetailsWorkUnit(entries: values))
                        return values
                    }
                    if split, try await cached(key + "/split") != nil { return try await halves() }
                    do {
                        let values = try await scheduler.perform(group: session.id) { try await extract(text, index) }
                        try await save(key, FastDetailsWorkUnit(entries: values))
                        return values
                    } catch {
                        try Task.checkCancellation()
                        guard split, text.count > 1, let reason = error as? SummaryResponseError,
                              [.invalidFormat, .responseTooLong, .responseStopped].contains(reason) else { throw error }
                        try await save(key + "/split", FastDetailsWorkUnit(entries: []))
                        return try await halves()
                    }
                }
                await progress("Reading section \(index + 1) of \(sources.count)…")
                let draft = try await extraction(source, key: prefix + "/extract", split: true)
                // A bounded split occurs only for malformed/truncated responses. Completed
                // sibling halves are durable, so a later failure does not repeat them.
                @Sendable func check(_ entries: [SummaryEntry], key: String, split: Bool, repair: Bool) async throws -> FastDetailsWorkUnit {
                    if let saved = try await cached(key) { return saved }
                    @Sendable func halves() async throws -> FastDetailsWorkUnit {
                        let middle = entries.count / 2
                        let left = try await check(Array(entries[..<middle]), key: key + "/a", split: false, repair: repair)
                        let right = try await check(Array(entries[middle...]), key: key + "/b", split: false, repair: repair)
                        let result = FastDetailsWorkUnit(entries: left.entries + right.entries, checks: (left.checks ?? []) + (right.checks ?? []))
                        try await save(key, result); return result
                    }
                    if split, entries.count > 1, try await cached(key + "/split") != nil { return try await halves() }
                    do {
                        let request = try FastDetailsCheck.request(entries, source: source, repair: repair)
                        let raw = try await scheduler.perform(group: session.id) { try await send(request) }
                        let checks = try FastDetailsCheck.decode(raw, entries: entries, source: source)
                        let assessed = entries.map { entry -> SummaryEntry in
                            var result = SummaryVerification.assess(entry, check: checks.first { $0.id == entry.id }, source: source)
                            result.evidence?.assessment?.sourceHash = SummaryVerification.hash(session.transcript)
                            return result
                        }
                        let result = FastDetailsWorkUnit(entries: assessed, checks: checks)
                        try await save(key, result); return result
                    } catch {
                        try Task.checkCancellation()
                        let recoverable: [SummaryResponseError] = [.invalidFormat, .missingDecisions, .duplicateDecisions, .wrongDecisions, .responseTooLong, .responseStopped]
                        guard split, entries.count > 1, let reason = error as? SummaryResponseError, recoverable.contains(reason) else { throw error }
                        try await save(key + "/split", FastDetailsWorkUnit(entries: []))
                        return try await halves()
                    }
                }
                await progress("Checking section \(index + 1) of \(sources.count)…")
                var reviewed: [SummaryEntry] = [], checks: [SummaryCheck] = []
                for start in stride(from: 0, to: draft.count, by: 16) {
                    let result = try await check(Array(draft.dropFirst(start).prefix(16)), key: prefix + "/check:\(start)", split: true, repair: false)
                    reviewed += result.entries; checks += result.checks ?? []
                }
                // Combine both repair reasons in one section-level pass (bounded at 16
                // claims per request). A statement-type correction remains a new claim
                // requiring independent verification, never an automatic approval.
                var candidates: [SummaryEntry] = []
                for entry in draft {
                    let verdict = checks.first { $0.id == entry.id }
                    if let corrected = SummaryVerification.statementTypeRepairCandidate(entry, check: verdict, source: source) { candidates.append(corrected) }
                    else if !SummaryVerification.citationRepairFields(entry, check: verdict, source: source).isEmpty { candidates.append(entry) }
                }
                for start in stride(from: 0, to: candidates.count, by: 16) {
                    let repaired = try await check(Array(candidates.dropFirst(start).prefix(16)), key: prefix + "/repair:\(start)", split: true, repair: true)
                    for entry in repaired.entries where entry.evidence?.assessment?.admission == .supported {
                        if let i = reviewed.firstIndex(where: { $0.id == entry.id }) { reviewed[i] = entry }
                    }
                }
                return reviewed
            }
            try Task.checkCancellation()
            await progress("Saving summary…")
            try await store.publishVerifiedSummary(expected: session, runID: run.id, entries: sections.flatMap { $0 })
        } catch {
            try? await store.updateSummaryRun(sessionID: session.id, runID: run.id,
                stage: error is CancellationError || Task.isCancelled ? .interrupted : .failed)
            throw error
        }
    }
}
