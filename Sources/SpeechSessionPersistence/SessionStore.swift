import Foundation

public enum SessionStoreError: Error, Equatable {
    case missingApplicationSupport
    case encodingFailed
    case decodingFailed
    case ioFailed(String)
}

/// File-backed persistence for sessions + folders using one JSON file and atomic replace writes.
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

    private func loadEnvelope() throws -> SessionsEnvelope {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SessionsEnvelope(sessions: [], folders: [])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(SessionsEnvelope.self, from: data)
        } catch is DecodingError {
            throw SessionStoreError.decodingFailed
        } catch {
            throw SessionStoreError.ioFailed(error.localizedDescription)
        }
    }

    private func saveEnvelope(_ envelope: SessionsEnvelope) throws {
        var env = envelope
        env.version = SessionsEnvelope.currentVersion
        let data: Data
        do {
            data = try encoder.encode(env)
        } catch {
            throw SessionStoreError.encodingFailed
        }
        try atomicWrite(data)
    }

    private func invalidateFolderSummary(_ envelope: inout SessionsEnvelope, folderID: UUID?) {
        guard let fid = folderID,
              let i = envelope.folders.firstIndex(where: { $0.id == fid })
        else { return }
        envelope.folders[i].cachedSummaryJSON = nil
        envelope.folders[i].cachedSummaryBackend = nil
    }

    /// Loads all sessions (every folder). Missing file yields an empty array.
    public func loadAll() throws -> [Session] {
        try loadEnvelope().sessions
    }

    public func loadFolders() throws -> [SessionFolder] {
        try loadEnvelope().folders
    }

    /// Replaces the on-disk session list with `sessions`, preserving folders.
    public func save(_ sessions: [Session]) throws {
        var env = try loadEnvelope()
        env.sessions = sessions
        try saveEnvelope(env)
    }

    /// Removes the session with the given `id` and saves.
    public func delete(id: UUID) throws {
        var env = try loadEnvelope()
        if let removed = env.sessions.first(where: { $0.id == id }) {
            invalidateFolderSummary(&env, folderID: removed.folderID)
        }
        env.sessions.removeAll { $0.id == id }
        try saveEnvelope(env)
    }

    /// Merges `session` by `id` (insert or replace), sorts by `date` descending, then saves.
    public func upsert(_ session: Session) throws {
        var env = try loadEnvelope()
        let previous = env.sessions.first { $0.id == session.id }
        invalidateFolderSummary(&env, folderID: previous?.folderID)
        if previous?.folderID != session.folderID {
            invalidateFolderSummary(&env, folderID: session.folderID)
        }
        if let index = env.sessions.firstIndex(where: { $0.id == session.id }) {
            env.sessions[index] = session
        } else {
            env.sessions.append(session)
        }
        env.sessions.sort { $0.date > $1.date }
        try saveEnvelope(env)
    }

    public func upsertFolder(_ folder: SessionFolder) throws {
        var env = try loadEnvelope()
        if let index = env.folders.firstIndex(where: { $0.id == folder.id }) {
            env.folders[index] = folder
        } else {
            env.folders.append(folder)
        }
        env.folders.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        try saveEnvelope(env)
    }

    public func deleteFolder(id: UUID) throws {
        var env = try loadEnvelope()
        env.folders.removeAll { $0.id == id }
        invalidateFolderSummary(&env, folderID: id)
        for idx in env.sessions.indices where env.sessions[idx].folderID == id {
            env.sessions[idx].folderID = nil
        }
        try saveEnvelope(env)
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
