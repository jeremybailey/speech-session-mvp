import Foundation

public enum SessionStoreError: Error, Equatable {
    case missingApplicationSupport
    case encodingFailed
    case decodingFailed
    case ioFailed(String)
}

/// File-backed persistence for sessions using a single JSON file and atomic replace writes.
public actor SessionStore {
    public static let sessionsFileName = "sessions.json"

    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - fileManager: inject for tests.
    ///   - storageDirectory: directory that will hold `sessions.json` (created if needed).
    public init(fileManager: FileManager = .default, storageDirectory: URL) throws {
        self.fileManager = fileManager
        self.directoryURL = storageDirectory
        self.fileURL = storageDirectory.appendingPathComponent(Self.sessionsFileName, isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    /// Application Support subdirectory suitable for production (iOS or macOS).
    public static func makeDefaultStorageDirectory(
        fileManager: FileManager = .default,
        subdirectory: String = "SpeechSessions"
    ) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SessionStoreError.missingApplicationSupport
        }
        return appSupport.appendingPathComponent(subdirectory, isDirectory: true)
    }

    /// Convenience factory using `makeDefaultStorageDirectory`.
    public static func appDefault(fileManager: FileManager = .default) throws -> SessionStore {
        let dir = try makeDefaultStorageDirectory(fileManager: fileManager)
        return try SessionStore(fileManager: fileManager, storageDirectory: dir)
    }

    /// Loads all sessions. Missing file yields an empty array.
    public func loadAll() throws -> [Session] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try decoder.decode(SessionsEnvelope.self, from: data)
            return envelope.sessions
        } catch is DecodingError {
            throw SessionStoreError.decodingFailed
        } catch {
            throw SessionStoreError.ioFailed(error.localizedDescription)
        }
    }

    /// Replaces the on-disk session list with `sessions` using an atomic write.
    public func save(_ sessions: [Session]) throws {
        let envelope = SessionsEnvelope(sessions: sessions)
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw SessionStoreError.encodingFailed
        }
        try atomicWrite(data)
    }

    /// Removes the session with the given `id` and saves.
    public func delete(id: UUID) throws {
        var all = try loadAll()
        all.removeAll { $0.id == id }
        try save(all)
    }

    /// Merges `session` by `id` (insert or replace), sorts by `date` descending, then saves.
    public func upsert(_ session: Session) throws {
        var all = try loadAll()
        if let index = all.firstIndex(where: { $0.id == session.id }) {
            all[index] = session
        } else {
            all.append(session)
        }
        all.sort { $0.date > $1.date }
        try save(all)
    }

    private func atomicWrite(_ data: Data) throws {
        let tempURL = directoryURL.appendingPathComponent("\(Self.sessionsFileName).tmp", isDirectory: false)
        do {
            try data.write(to: tempURL, options: [.atomic])
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw SessionStoreError.ioFailed(error.localizedDescription)
        }
    }
}
