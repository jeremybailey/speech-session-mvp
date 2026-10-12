import Foundation
import CryptoKit
import SpeechSessionPersistence

private actor RunPhases {
    var rows: [[String: String]] = []
    func add(record: String, seconds: Double, failure: String?) {
        rows.append(["recordID": record, "seconds": String(seconds), "failure": failure ?? ""])
    }
}
@main struct FastRun {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 4, args[3] == "reuse" {
            let out = URL(fileURLWithPath: args[1]).appendingPathComponent(args[2])
            let directory = out.appendingPathComponent("store")
            let file = directory.appendingPathComponent(SessionStore.sessionsFileName)
            let before = try Data(contentsOf: file), store = try SessionStore(storageDirectory: directory)
            let sessions = try await store.healthSnapshot().sessions
            let scheduler = FastDetailsScheduler(), pipeline = FastDetailsPipeline(scheduler: scheduler)
            let start = ProcessInfo.processInfo.systemUptime
            for session in sessions {
                try await pipeline.process(session: session, sources: [session.transcript], store: store,
                    extract: { _, _ in throw SummaryProcessingError.unavailable("Reuse unexpectedly requested extraction") },
                    send: { _ in throw SummaryProcessingError.unavailable("Reuse unexpectedly requested checking") })
            }
            let elapsed = ProcessInfo.processInfo.systemUptime-start
            guard try Data(contentsOf: file) == before else { throw SummaryCommitError.sourceChanged }
            let metrics = await scheduler.metrics
            try JSONSerialization.data(withJSONObject: ["records": sessions.count, "seconds": elapsed,
                "providerRequests": metrics.operations, "savedBytesUnchanged": true,
                "scope": "Local completed-fact reuse only; not cold reprocessing or template generation"])
                .write(to: out.appendingPathComponent("reuse.json"))
            print("Completed facts reused locally with zero provider requests.")
            return
        }
        if args.count == 5, args[3] == "check" {
            let root = URL(fileURLWithPath: args[1]), run = args[2]
            struct Fixture: Decodable { let source: String; let entries: [SummaryEntry] }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
            let out = root.appendingPathComponent(run)
            let resumed = FileManager.default.fileExists(atPath: out.path)
            let bridge = try BenchmarkBridge(root: root, run: run, trace: out.appendingPathComponent("trace"))
            let ledger = try await bridge.send(["action": "status"])
            try JSONSerialization.data(withJSONObject: ledger).write(to: out.appendingPathComponent("preflight-accounting.json"))
            let start = ProcessInfo.processInfo.systemUptime
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            func check(_ entries: [SummaryEntry], key: String, split: Bool) async throws -> [SummaryCheck] {
                let saved = out.appendingPathComponent(key + ".json")
                if FileManager.default.fileExists(atPath: saved.path) {
                    return try decoder.decode([SummaryCheck].self, from: Data(contentsOf: saved))
                }
                let marker = out.appendingPathComponent(key + "-split.json")
                func halves() async throws -> [SummaryCheck] {
                    let middle = entries.count / 2
                    let left = try await check(Array(entries[..<middle]), key: key + "-a", split: false)
                    let right = try await check(Array(entries[middle...]), key: key + "-b", split: false)
                    return left + right
                }
                let checks: [SummaryCheck]
                if split, FileManager.default.fileExists(atPath: marker.path) { checks = try await halves() }
                else {
                    do {
                        let request = try FastDetailsCheck.request(entries, source: fixture.source)
                        let raw = try await bridge.perform(payload: ["stage": request.stage,
                            "instructions": "Pipeline: " + FastDetailsPipeline.version + "\n" + request.instructions,
                            "input": request.input, "response_format": try JSONSerialization.jsonObject(with: request.responseFormat),
                            "diagnostic_phase": "checking"], conditionWorkflow: false)
                        checks = try FastDetailsCheck.decode(raw, entries: entries, source: fixture.source)
                    } catch {
                        guard split, entries.count > 1, let reason = error as? SummaryResponseError,
                              [.invalidFormat, .responseTooLong, .responseStopped].contains(reason) else { throw error }
                        try Data("{}".utf8).write(to: marker)
                        checks = try await halves()
                    }
                }
                try encoder.encode(checks).write(to: saved)
                return checks
            }
            let checks = try await check(fixture.entries, key: "checked", split: true)
            let entries = fixture.entries.map { entry in SummaryVerification.assess(entry, check: checks.first { $0.id == entry.id }, source: fixture.source) }
            try encoder.encode(checks).write(to: out.appendingPathComponent("checks.json"))
            try encoder.encode(entries).write(to: out.appendingPathComponent("entries.json"))
            try JSONSerialization.data(withJSONObject: ["seconds": ProcessInfo.processInfo.systemUptime-start,
                "resumed": resumed, "assertions": fixture.entries.count, "scope": "Identical saved assertions and source context; no extraction"])
                .write(to: out.appendingPathComponent("replay.json"))
            print("Saved-assertion checker replay completed.")
            return
        }
        guard args.count == 5, ["one", "all", "resume-one", "resume-all"].contains(args[3]), let limit = Int(args[4]), (1...4).contains(limit) else {
            fatalError("Usage: fast-replay experiment-root run-name one|all|resume-one|resume-all concurrency")
        }
        let root = URL(fileURLWithPath: args[1]), run = args[2], resumed = args[3].hasPrefix("resume-")
        let out = root.appendingPathComponent(run), storeURL = out.appendingPathComponent("store")
        if !resumed {
            guard !FileManager.default.fileExists(atPath: out.path) else { fatalError("Cold run cannot reuse prior output") }
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent("seed.json"), to: storeURL.appendingPathComponent(SessionStore.sessionsFileName))
        } else { guard FileManager.default.fileExists(atPath: storeURL.path) else { fatalError("Resume requires saved checkpoints") } }
        let provenance = out.appendingPathComponent(resumed ? "source-hashes-resume-\(Int(Date().timeIntervalSince1970)).json" : "source-hashes.json")
        try FileManager.default.copyItem(at: root.appendingPathComponent("compiled-source-hashes.json"), to: provenance)
        let store = try SessionStore(storageDirectory: storeURL)
        let initial = try await store.healthSnapshot()
        guard initial.sessions.count == 5 else { fatalError("Expected frozen five-record snapshot") }
        let selected = args[3].hasSuffix("one") ? [initial.sessions.max(by: { $0.transcript.count < $1.transcript.count })!] : initial.sessions
        let bridge = try BenchmarkBridge(root: root, run: run, trace: out.appendingPathComponent("trace"))
        let accounting = try await bridge.send(["action": "status"])
        guard let jobs = accounting["jobs"] as? [[String: Any]], let budget = accounting["budget"] as? [String: Any] else { throw SummaryResponseError.invalidFormat }
        func amount(_ value: Any?) throws -> Int64 {
            guard let value, let number = Int64(String(describing: value)), number >= 0 else { throw SummaryResponseError.invalidFormat }
            return number
        }
        var committed: Int64 = 0
        for job in jobs { committed += try amount(job["cost_nusd"] is NSNull || job["cost_nusd"] == nil ? job["reserve_nusd"] : job["cost_nusd"]) }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
        guard let cap = manifest["experimentLimitUSD"] as? Double else { throw SummaryResponseError.invalidFormat }
        let sharedRemaining = try amount(budget["limit_nusd"]) - amount(budget["used_nusd"]) - amount(budget["reserved_nusd"])
        // Conservative Luna extraction reservation, pinned by the unchanged model/output policy.
        let required = Int64(limit) * 217_500_000
        guard required <= min(Int64(cap * 1e9) - committed, sharedRemaining) else { throw SummaryResponseError.quotaExceeded }
        try JSONSerialization.data(withJSONObject: accounting, options: [.sortedKeys]).write(to: out.appendingPathComponent("preflight-accounting.json"))
        let transport = OpenAIChatTransport(bridge: bridge), phases = RunPhases(), scheduler = FastDetailsScheduler(limit: limit)
        let started = ProcessInfo.processInfo.systemUptime
        let success = try await SummaryParallelWork.map(selected, limit: 3) { record -> Bool in
            let begin = ProcessInfo.processInfo.systemUptime
            do {
                try await FastRecordProcessing.process(record, store: store, transport: transport, scheduler: scheduler) { _ in }
                await phases.add(record: record.id.uuidString, seconds: ProcessInfo.processInfo.systemUptime - begin, failure: nil)
                return true
            } catch {
                await phases.add(record: record.id.uuidString, seconds: ProcessInfo.processInfo.systemUptime - begin, failure: String(describing: error))
                return false
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let snapshot = try await store.healthSnapshot(), encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for session in snapshot.sessions where selected.contains(where: { $0.id == session.id }) {
            let rows = try (session.summaryEntries ?? []).map { entry -> [String: Any] in
                var row = try JSONSerialization.jsonObject(with: encoder.encode(entry)) as! [String: Any]
                row["visible"] = SummaryVerification.isVisible(entry, source: session.transcript)
                row["conditions"] = [] as [String] // Explicitly unmeasured in a details-only run.
                return row
            }
            let output: [String: Any] = ["recordID": session.id.uuidString, "mode": run, "entries": rows,
                "sourceSHA256": SHA256.hash(data: Data(session.transcript.utf8)).map { String(format: "%02x", $0) }.joined()]
            try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys]).write(to: out.appendingPathComponent(session.id.uuidString + ".output.json"))
        }
        let sourceUnchanged = initial.sessions.allSatisfy { old in snapshot.sessions.contains { $0.id == old.id && $0.transcript == old.transcript } }
        let recordPhases = await phases.rows
        let schedulerMetrics = try JSONSerialization.jsonObject(with: encoder.encode(await scheduler.metrics))
        let result: [String: Any] = ["run": run, "pipeline": FastDetailsPipeline.version, "cold": !resumed,
            "completed": success.allSatisfy { $0 } && sourceUnchanged, "elapsedSeconds": elapsed,
            "schedulerMetrics": schedulerMetrics, "records": selected.count, "concurrency": limit, "phases": recordPhases,
            "originalTranscriptsPreserved": sourceUnchanged,
            "scope": "Health details only: extraction, independent checks, repair, atomic record publication. Excludes consolidation, conditions and overview."]
        let report = out.appendingPathComponent(resumed ? "resume-\(Int(Date().timeIntervalSince1970)).json" : "run.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: report)
        if let ledger = try? await bridge.send(["action": "status"]) {
            try JSONSerialization.data(withJSONObject: ledger, options: [.prettyPrinted,.sortedKeys]).write(to: out.appendingPathComponent("ledger.json"))
        }
        print("Fast details: \(success.filter { $0 }.count)/\(selected.count) records completed in \(Int(elapsed)) seconds. See private report.")
    }
}
