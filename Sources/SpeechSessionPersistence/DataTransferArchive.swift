import Foundation
import CryptoKit
import ZipArchive
import TransferZip

public enum DataTransferError: LocalizedError {
    case invalidArchive, unsupportedVersion, wrongPassword, passwordTooShort, tooLarge, insufficientSpace, missingOriginals(Int), busy
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "This ZIP file is damaged or contains invalid data. Your current history has not been replaced."
        case .unsupportedVersion: return "This ZIP file requires a newer version of CollectiveCare."
        case .wrongPassword: return "The password is incorrect, or the encrypted ZIP file is damaged."
        case .passwordTooShort: return "Use at least \(DataTransferArchive.minimumPasswordLength) characters. Words and spaces are fine; numbers and symbols are optional."
        case .tooLarge: return "This ZIP file exceeds the limit of 20,000 files or 5 GiB of uncompressed data."
        case .insufficientSpace: return "There is not enough free space to transfer this history safely."
        case .missingOriginals(let count): return "\(count) original files are unavailable. Export text only, or explicitly continue without those files."
        case .busy: return "Wait for recording and processing to finish before transferring data."
        }
    }
}

public struct DataTransferManifest: Codable, Sendable {
    public let version: Int
    public let exportID: UUID
    public let exportedAt: Date
    public let appVersion: String
    public let includesOriginals: Bool
    public let missingOriginalCount: Int
    public let records: [Record]
    public let files: [File]
    public struct Record: Codable, Sendable {
        public let id: UUID
        public let title: String?
        public let sourceTextSHA256: String
        public let sourceTextFile: String
    }
    public struct File: Codable, Sendable {
        public let archiveName: String
        public let destination: String
        public let size: UInt64
        public let sha256: String
    }
}

public struct PreparedDataImport: Sendable {
    public let manifest: DataTransferManifest
    let directory: URL
}

/// This format deliberately accepts only flat opaque archive entries. It never
/// delegates untrusted paths or unbounded decompression to a general unzip API.
public enum DataTransferArchive {
    public static let minimumPasswordLength = 12
    public static let maxBytes: UInt64 = 5 * 1024 * 1024 * 1024
    public static let maxFiles = 20_000
    static let metadataLimit: UInt64 = 128 * 1024 * 1024
    static let importedMarker = "imported-history.json"
    static let savedResults = ["condition-synthesis.json", "story-overview.json"]
    static let fm = FileManager.default

    static func workRoot(_ root: URL) -> URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".transfer-work") }
    static func rollbackRoot(_ root: URL) -> URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".transfer-rollback") }
    static func commitMarker(_ root: URL) -> URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".transfer-committed") }

    static func protect(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    static func createDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try protect(url)
    }

    static func requireSpace(_ bytes: UInt64, at root: URL) throws {
        let values = try fm.attributesOfFileSystem(forPath: root.path)
        guard let free = (values[.systemFreeSize] as? NSNumber)?.uint64Value,
              free > bytes + 64 * 1024 * 1024 else { throw DataTransferError.insufficientSpace }
    }

    static func digest(_ url: URL) throws -> (UInt64, String) {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256(); var count: UInt64 = 0
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += UInt64(data.count)
            guard count <= maxBytes else { throw DataTransferError.tooLarge }
            hash.update(data: data)
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func textHash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func regularFile(_ url: URL) -> Bool {
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return value.isRegularFile == true && value.isSymbolicLink != true
    }

    static func originalURL(_ asset: SessionSourceAsset, sessionID: UUID, root: URL) -> URL? {
        guard safeRelativePath(asset.relativePath) else { return nil }
        let canonicalRoot = root.resolvingSymlinksInPath()
        let url = canonicalRoot.appendingPathComponent("sources/\(sessionID.uuidString)/\(asset.relativePath)")
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path, regularFile(url) else { return nil }
        return url
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func enforceLimit(count: Int, bytes: UInt64) throws {
        guard count <= maxFiles, bytes <= maxBytes else { throw DataTransferError.tooLarge }
    }

    /// Before the durable commit marker, recover the previous history. After it,
    /// keep the complete new history even if rollback cleanup was interrupted.
    static func recoverReplacement(at root: URL) throws {
        let rollback = rollbackRoot(root)
        let committed = commitMarker(root)
        if fm.fileExists(atPath: rollback.path) {
            if fm.fileExists(atPath: committed.path), fm.fileExists(atPath: root.path) {
                try fm.removeItem(at: rollback)
            } else {
                if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
                try fm.moveItem(at: rollback, to: root)
            }
        }
        if fm.fileExists(atPath: committed.path) { try fm.removeItem(at: committed) }
        let work = workRoot(root)
        if fm.fileExists(atPath: work.path) { try fm.removeItem(at: work) }
    }

    static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]
        return value
    }
    static func decoder() -> JSONDecoder {
        let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value
    }

    static func validateEnvelope(_ envelope: SessionsEnvelope) throws {
        guard envelope.version == SessionsEnvelope.currentVersion else { throw DataTransferError.unsupportedVersion }
        let sessions = Set(envelope.sessions.map(\.id)); let folders = Set(envelope.folders.map(\.id))
        let entries = envelope.sessions.flatMap { $0.summaryEntries ?? [] }
        guard sessions.count == envelope.sessions.count, folders.count == envelope.folders.count,
              Set(entries.map(\.id)).count == entries.count,
              Set(envelope.topics.map(\.id)).count == envelope.topics.count,
              Set(envelope.careTeam.map(\.id)).count == envelope.careTeam.count,
              Set(envelope.preferences.map(\.id)).count == envelope.preferences.count else { throw DataTransferError.invalidArchive }
        for session in envelope.sessions {
            guard session.folderID.map({ folders.contains($0) }) ?? true else { throw DataTransferError.invalidArchive }
            let assets = session.sourceAssets ?? []
            guard Set(assets.map(\.id)).count == assets.count,
                  Set(assets.map { $0.relativePath.lowercased() }).count == assets.count,
                  assets.allSatisfy({ safeRelativePath($0.relativePath) }),
                  (session.summaryEntries ?? []).allSatisfy({ $0.sourceSessionID.map { sessions.contains($0) } ?? true }) else { throw DataTransferError.invalidArchive }
        }
    }

    static func extract(_ zip: URL, password: String, to output: URL) throws {
        guard let archive = cc_zip_open(zip.path) else { throw DataTransferError.invalidArchive }
        defer { cc_zip_close(archive) }
        var names = Set<String>(); var declared: UInt64 = 0
        var status = cc_zip_first(archive)
        // Preflight every entry before writing any clinical payload.
        while status == 0 {
            try Task.checkCancellation()
            let info = try entryInfo(archive)
            guard names.insert(info.name.lowercased()).inserted else { throw DataTransferError.invalidArchive }
            guard info.size <= maxBytes - declared else { throw DataTransferError.tooLarge }
            declared += info.size
            try enforceLimit(count: names.count, bytes: declared)
            status = cc_zip_next(archive)
        }
        guard status == -100, names.contains("manifest.json") else { throw DataTransferError.invalidArchive }
        try requireSpace(declared * 2, at: output)
        status = cc_zip_first(archive)
        var actual: UInt64 = 0
        while status == 0 {
            let info = try entryInfo(archive)
            let target = output.appendingPathComponent(info.name)
            guard cc_zip_read_open(archive, password) == 0 else { throw DataTransferError.wrongPassword }
            var closed = false
            defer { if !closed { cc_zip_read_close(archive) } }
            try write(Data(), to: target)
            let file = try FileHandle(forWritingTo: target); defer { try? file.close() }
            var written: UInt64 = 0; var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let count = cc_zip_read(archive, &buffer, UInt32(buffer.count))
                guard count >= 0 else { throw DataTransferError.wrongPassword }
                if count == 0 { break }
                written += UInt64(count); actual += UInt64(count)
                guard written <= info.size, actual <= maxBytes else { throw DataTransferError.tooLarge }
                try file.write(contentsOf: Data(buffer.prefix(Int(count))))
            }
            let closeResult = cc_zip_read_close(archive); closed = true
            guard closeResult == 0, written == info.size else { throw DataTransferError.wrongPassword }
            status = cc_zip_next(archive)
        }
        guard status == -100 else { throw DataTransferError.invalidArchive }
    }

    static func entryInfo(_ archive: UnsafeMutableRawPointer) throws -> (name: String, size: UInt64) {
        var name = [CChar](repeating: 0, count: 256)
        var size: UInt64 = 0; var attributes: UInt32 = 0; var flags: UInt16 = 0; var method: UInt16 = 0
        guard cc_zip_info(archive, &name, UInt32(name.count), &size, &attributes, &flags, &method) == 0 else { throw DataTransferError.invalidArchive }
        let path = String(cString: name)
        let fileType = (attributes >> 16) & 0xf000
        guard path == "manifest.json" || UUID(uuidString: path) != nil,
              fileType == 0 || fileType == 0x8000, attributes & 0x10 == 0,
              flags & 1 == 1, method == 99 else { throw DataTransferError.invalidArchive }
        guard path != "manifest.json" || size <= metadataLimit else { throw DataTransferError.tooLarge }
        return (path, size)
    }

    static func validate(_ directory: URL) throws -> (DataTransferManifest, SessionsEnvelope) {
        let manifest = try decoder().decode(DataTransferManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.version == 1 else { throw DataTransferError.unsupportedVersion }
        guard manifest.files.count < maxFiles, Set(manifest.files.map(\.archiveName)).count == manifest.files.count,
              Set(manifest.files.map { $0.destination.lowercased() }).count == manifest.files.count else { throw DataTransferError.invalidArchive }
        let actualNames = Set(try fm.contentsOfDirectory(atPath: directory.path))
        guard actualNames == Set(manifest.files.map(\.archiveName)).union(["manifest.json"]) else { throw DataTransferError.invalidArchive }
        var total: UInt64 = 0
        for file in manifest.files {
            guard UUID(uuidString: file.archiveName) != nil, safeRelativePath(file.destination),
                  regularFile(directory.appendingPathComponent(file.archiveName)) else { throw DataTransferError.invalidArchive }
            let (size, hash) = try digest(directory.appendingPathComponent(file.archiveName))
            guard size == file.size, hash == file.sha256, size <= maxBytes - total else { throw DataTransferError.invalidArchive }
            total += size
        }
        guard let sessions = manifest.files.first(where: { $0.destination == SessionStore.sessionsFileName }), sessions.size <= metadataLimit else { throw DataTransferError.invalidArchive }
        let envelope = try decoder().decode(SessionsEnvelope.self, from: Data(contentsOf: directory.appendingPathComponent(sessions.archiveName)))
        try validateEnvelope(envelope)
        guard Set(manifest.records.map(\.id)).count == manifest.records.count,
              Set(manifest.records.map(\.id)) == Set(envelope.sessions.map(\.id)) else { throw DataTransferError.invalidArchive }
        let allowedSources = Set(envelope.sessions.flatMap { session in (session.sourceAssets ?? []).map { "sources/\(session.id.uuidString)/\($0.relativePath)" } })
        let allowedTexts = Set(envelope.sessions.map { "texts/\($0.id.uuidString).txt" })
        let allowed = allowedSources.union(allowedTexts).union(savedResults).union([SessionStore.sessionsFileName])
        guard manifest.files.allSatisfy({ allowed.contains($0.destination) && (manifest.includesOriginals || !$0.destination.hasPrefix("sources/")) }) else { throw DataTransferError.invalidArchive }
        guard manifest.missingOriginalCount >= 0, manifest.missingOriginalCount <= allowedSources.count else { throw DataTransferError.invalidArchive }
        if manifest.includesOriginals {
            guard manifest.files.filter({ $0.destination.hasPrefix("sources/") }).count + manifest.missingOriginalCount == allowedSources.count else { throw DataTransferError.invalidArchive }
        }
        let sessionsByID = Dictionary(uniqueKeysWithValues: envelope.sessions.map { ($0.id, $0) })
        let filesByName = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.archiveName, $0) })
        for record in manifest.records {
            guard let session = sessionsByID[record.id],
                  record.sourceTextSHA256 == textHash(session.transcript),
                  let file = filesByName[record.sourceTextFile],
                  file.destination == "texts/\(session.id.uuidString).txt",
                  file.sha256 == record.sourceTextSHA256 else { throw DataTransferError.invalidArchive }
        }
        // Decode saved result caches before they become trusted local files. The
        // normal projection additionally checks fingerprints against current data.
        for file in manifest.files where savedResults.contains(file.destination) {
            guard file.size <= metadataLimit else { throw DataTransferError.tooLarge }
            let data = try Data(contentsOf: directory.appendingPathComponent(file.archiveName))
            if file.destination == "condition-synthesis.json" {
                let saved = try JSONDecoder().decode(StoredConditionSynthesis.self, from: data)
                let ids = Set(envelope.sessions.flatMap { ($0.summaryEntries ?? []).map(\.id) })
                let mappedIDs = saved.synthesis.groups.flatMap(\.entryIDs) + saved.synthesis.unassigned
                guard Set(mappedIDs).isSubset(of: ids), Set(mappedIDs).count == mappedIDs.count,
                      saved.synthesis.groups.allSatisfy({ Set($0.entryReasons?.keys.map { $0 } ?? []).isSubset(of: Set($0.entryIDs)) }),
                      Set(saved.synthesis.groups.compactMap(\.stableID)).count == saved.synthesis.groups.compactMap(\.stableID).count else { throw DataTransferError.invalidArchive }
            } else {
                let saved = try JSONDecoder().decode(StoredStoryOverview.self, from: data)
                let snapshot = HealthMemorySnapshot(sessions: envelope.sessions, folders: envelope.folders, topics: envelope.topics,
                                                    careTeam: envelope.careTeam, preferences: envelope.preferences, profile: envelope.profile)
                guard saved.overview.hasValidReferences(in: HealthMemoryProjection.facts(in: snapshot)) else { throw DataTransferError.invalidArchive }
            }
        }
        return (manifest, envelope)
    }
}

extension SessionStore {
    public var isImportedHistory: Bool { FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent(DataTransferArchive.importedMarker).path) }

    public func missingOriginalCount() throws -> Int {
        return try transferEnvelope().sessions.reduce(0) { count, session in
            count + (session.sourceAssets ?? []).filter { DataTransferArchive.originalURL($0, sessionID: session.id, root: storageDirectory) == nil }.count
        }
    }

    public func exportData(password: String, includeOriginals: Bool, allowMissingOriginals: Bool = false, appVersion: String) throws -> URL {
        guard password.count >= DataTransferArchive.minimumPasswordLength else { throw DataTransferError.passwordTooShort }
        let missing = try missingOriginalCount()
        if includeOriginals && missing > 0 && !allowMissingOriginals { throw DataTransferError.missingOriginals(missing) }
        let work = DataTransferArchive.workRoot(storageDirectory)
        if FileManager.default.fileExists(atPath: work.path) { try FileManager.default.removeItem(at: work) }
        try DataTransferArchive.createDirectory(work)
        let payload = work.appendingPathComponent("payload")
        try DataTransferArchive.createDirectory(payload)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: work) } }
        var envelope = try transferEnvelope()
        for i in envelope.sessions.indices {
            envelope.sessions[i].summaryRun = nil
            envelope.sessions[i].summaryDrafts = nil
            envelope.sessions[i].processingState = nil
            envelope.sessions[i].processingError = nil
        }
        try DataTransferArchive.validateEnvelope(envelope)
        var files: [DataTransferManifest.File] = []; var records: [DataTransferManifest.Record] = []; var total: UInt64 = 0
        func add(_ destination: String, data: Data? = nil, source: URL? = nil) throws -> String {
            try Task.checkCancellation()
            guard files.count + 2 <= DataTransferArchive.maxFiles else { throw DataTransferError.tooLarge }
            let name = UUID().uuidString; let target = payload.appendingPathComponent(name)
            if let data {
                guard UInt64(data.count) <= DataTransferArchive.maxBytes - total,
                      destination != SessionStore.sessionsFileName || UInt64(data.count) <= DataTransferArchive.metadataLimit else { throw DataTransferError.tooLarge }
                try DataTransferArchive.requireSpace(UInt64(data.count) * 2, at: work)
                try DataTransferArchive.write(data, to: target)
            }
            else if let source {
                guard DataTransferArchive.regularFile(source) else { throw DataTransferError.invalidArchive }
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard UInt64(size) <= DataTransferArchive.maxBytes - total else { throw DataTransferError.tooLarge }
                try DataTransferArchive.requireSpace(UInt64(size) * 2, at: work)
                try FileManager.default.copyItem(at: source, to: target); try DataTransferArchive.protect(target)
            }
            let (size, hash) = try DataTransferArchive.digest(target)
            guard size <= DataTransferArchive.maxBytes - total else { throw DataTransferError.tooLarge }
            total += size
            files.append(.init(archiveName: name, destination: destination, size: size, sha256: hash))
            return name
        }
        _ = try add(SessionStore.sessionsFileName, data: DataTransferArchive.encoder().encode(envelope))
        for session in envelope.sessions {
            let name = try add("texts/\(session.id.uuidString).txt", data: Data(session.transcript.utf8))
            records.append(.init(id: session.id, title: session.title, sourceTextSHA256: DataTransferArchive.textHash(session.transcript), sourceTextFile: name))
            if includeOriginals {
                for asset in session.sourceAssets ?? [] {
                    if let url = DataTransferArchive.originalURL(asset, sessionID: session.id, root: storageDirectory) {
                        _ = try add("sources/\(session.id.uuidString)/\(asset.relativePath)", source: url)
                    }
                }
            }
        }
        for result in DataTransferArchive.savedResults {
            let url = storageDirectory.appendingPathComponent(result)
            if DataTransferArchive.regularFile(url) {
                let data = try Data(contentsOf: url)
                if result == "condition-synthesis.json" {
                    var saved = try JSONDecoder().decode(StoredConditionSynthesis.self, from: data)
                    let ids = Set(envelope.sessions.flatMap { ($0.summaryEntries ?? []).map(\.id) })
                    // Deleted entries can remain in an incremental cache. Retain
                    // surviving accepted mappings without exporting dangling links.
                    saved.synthesis.groups = saved.synthesis.groups.compactMap { group in
                        var group = group; group.entryIDs = group.entryIDs.filter { ids.contains($0) }
                        group.entryReasons = group.entryReasons?.filter { group.entryIDs.contains($0.key) }
                        return group.entryIDs.isEmpty ? nil : group
                    }
                    saved.synthesis.unassigned = saved.synthesis.unassigned.filter { ids.contains($0) }
                    _ = try add(result, data: JSONEncoder().encode(saved))
                } else {
                    let saved = try JSONDecoder().decode(StoredStoryOverview.self, from: data)
                    let snapshot = HealthMemorySnapshot(sessions: envelope.sessions, folders: envelope.folders, topics: envelope.topics,
                                                        careTeam: envelope.careTeam, preferences: envelope.preferences, profile: envelope.profile)
                    if saved.overview.hasValidReferences(in: HealthMemoryProjection.facts(in: snapshot)) { _ = try add(result, source: url) }
                }
            }
        }
        let manifest = DataTransferManifest(version: 1, exportID: UUID(), exportedAt: Date(), appVersion: appVersion,
                                            includesOriginals: includeOriginals, missingOriginalCount: missing, records: records, files: files)
        let manifestData = try DataTransferArchive.encoder().encode(manifest)
        guard UInt64(manifestData.count) <= DataTransferArchive.metadataLimit,
              UInt64(manifestData.count) <= DataTransferArchive.maxBytes - total else { throw DataTransferError.tooLarge }
        try DataTransferArchive.write(manifestData, to: payload.appendingPathComponent("manifest.json"))
        _ = try DataTransferArchive.validate(payload)
        try DataTransferArchive.requireSpace(total + 1024 * 1024, at: work)
        let zip = work.appendingPathComponent("CollectiveCare-\(manifest.exportID.uuidString).zip")
        let writer = SSZipArchive(path: zip.path)
        guard writer.open() else { throw DataTransferError.invalidArchive }
        var closed = false
        defer { if !closed { writer.close() } }
        for name in files.map(\.archiveName) + ["manifest.json"] {
            try Task.checkCancellation()
            guard writer.writeFile(atPath: payload.appendingPathComponent(name).path, withFileName: name, compressionLevel: -1, password: password, aes: true) else { throw DataTransferError.invalidArchive }
        }
        guard writer.close() else { throw DataTransferError.invalidArchive }; closed = true
        try DataTransferArchive.protect(zip)
        try FileManager.default.removeItem(at: payload)
        succeeded = true
        return zip
    }

    public func prepareDataImport(from zip: URL, password: String) throws -> PreparedDataImport {
        let work = DataTransferArchive.workRoot(storageDirectory)
        if FileManager.default.fileExists(atPath: work.path) { try FileManager.default.removeItem(at: work) }
        try DataTransferArchive.createDirectory(work)
        let payload = work.appendingPathComponent("payload")
        try DataTransferArchive.createDirectory(payload)
        do {
            try DataTransferArchive.extract(zip, password: password, to: payload)
            let (manifest, _) = try DataTransferArchive.validate(payload)
            return PreparedDataImport(manifest: manifest, directory: payload)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    public func replaceWithImportedData(_ prepared: PreparedDataImport) throws {
        let work = DataTransferArchive.workRoot(storageDirectory)
        guard prepared.directory.standardizedFileURL.path == work.appendingPathComponent("payload").standardizedFileURL.path else { throw DataTransferError.invalidArchive }
        let (manifest, original) = try DataTransferArchive.validate(prepared.directory)
        try DataTransferArchive.requireSpace(manifest.files.reduce(0) { $0 + $1.size }, at: work)
        let incoming = work.appendingPathComponent("incoming")
        try DataTransferArchive.createDirectory(incoming)
        var envelope = original
        for i in envelope.sessions.indices {
            envelope.sessions[i].summaryRun = nil; envelope.sessions[i].summaryDrafts = nil
            envelope.sessions[i].processingState = nil; envelope.sessions[i].processingError = nil
        }
        try DataTransferArchive.write(DataTransferArchive.encoder().encode(envelope), to: incoming.appendingPathComponent(SessionStore.sessionsFileName))
        for file in manifest.files where file.destination != SessionStore.sessionsFileName && !file.destination.hasPrefix("texts/") {
            try Task.checkCancellation()
            let destination = incoming.appendingPathComponent(file.destination)
            try DataTransferArchive.createDirectory(destination.deletingLastPathComponent())
            try FileManager.default.copyItem(at: prepared.directory.appendingPathComponent(file.archiveName), to: destination)
            try DataTransferArchive.protect(destination)
        }
        // Persist provenance and the no-auto-processing policy with the replacement,
        // not in account preferences, so interruption cannot enable processing.
        try DataTransferArchive.write(DataTransferArchive.encoder().encode(manifest), to: incoming.appendingPathComponent(DataTransferArchive.importedMarker))
        try Task.checkCancellation()
        let rollback = DataTransferArchive.rollbackRoot(storageDirectory)
        guard !FileManager.default.fileExists(atPath: rollback.path) else { throw DataTransferError.busy }
        try FileManager.default.moveItem(at: storageDirectory, to: rollback)
        do {
            try FileManager.default.moveItem(at: incoming, to: storageDirectory)
            try DataTransferArchive.write(Data("committed".utf8), to: DataTransferArchive.commitMarker(storageDirectory))
        } catch {
            try DataTransferArchive.recoverReplacement(at: storageDirectory)
            invalidateTransferCache()
            throw error
        }
        // A committed replacement stays installed even when cleanup fails or the
        // process terminates during recursive removal of the previous history.
        invalidateTransferCache()
        try? FileManager.default.removeItem(at: rollback)
        if !FileManager.default.fileExists(atPath: rollback.path) {
            try? FileManager.default.removeItem(at: DataTransferArchive.commitMarker(storageDirectory))
        }
        try? FileManager.default.removeItem(at: work)
    }

    public func discardDataTransfer() throws {
        let work = DataTransferArchive.workRoot(storageDirectory)
        if FileManager.default.fileExists(atPath: work.path) { try FileManager.default.removeItem(at: work) }
    }
}
