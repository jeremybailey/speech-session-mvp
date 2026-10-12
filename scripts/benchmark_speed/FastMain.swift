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
