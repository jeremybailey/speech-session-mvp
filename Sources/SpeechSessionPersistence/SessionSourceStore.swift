import Foundation

public enum SessionSourceStoreError: Error, Equatable, Sendable {
    case ioFailed(String)
    case invalidRelativePath
}

/// Persists original session source files under `{storageDirectory}/sources/{sessionID}/`.
public struct SessionSourceStore: Sendable {
    public static let sourcesDirectoryName = "sources"

    private let fileManager: FileManager
    private let storageDirectory: URL

    public init(fileManager: FileManager = .default, storageDirectory: URL) {
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory
    }

    public func sessionSourcesDirectory(sessionID: UUID) -> URL {
        storageDirectory
            .appendingPathComponent(Self.sourcesDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    public func url(for asset: SessionSourceAsset, sessionID: UUID) -> URL {
        sessionSourcesDirectory(sessionID: sessionID)
            .appendingPathComponent(asset.relativePath, isDirectory: false)
    }

    /// Copies a file from disk into the session sources folder.
    public func copyFile(
        from sourceURL: URL,
        sessionID: UUID,
        displayName: String,
        kind: SessionSourceKind
    ) throws -> SessionSourceAsset {
        let ext = sourceURL.pathExtension.isEmpty ? defaultExtension(for: kind) : sourceURL.pathExtension
        let fileName = uniqueFileName(prefix: sanitizedBaseName(displayName), ext: ext, sessionID: sessionID)
        let destination = sessionSourcesDirectory(sessionID: sessionID)
            .appendingPathComponent(fileName, isDirectory: false)
        try ensureSessionDirectory(sessionID: sessionID)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return SessionSourceAsset(
            kind: kind,
            relativePath: fileName,
            displayName: displayName
        )
    }

    /// Writes raw bytes into the session sources folder.
    public func saveData(
        _ data: Data,
        sessionID: UUID,
        fileName: String,
        displayName: String,
        kind: SessionSourceKind,
        pageIndex: Int? = nil
    ) throws -> SessionSourceAsset {
        try ensureSessionDirectory(sessionID: sessionID)
        let safeName = sanitizedFileName(fileName)
        let destination = sessionSourcesDirectory(sessionID: sessionID)
            .appendingPathComponent(safeName, isDirectory: false)
        try data.write(to: destination, options: [.atomic])
        return SessionSourceAsset(
            kind: kind,
            relativePath: safeName,
            displayName: displayName,
            pageIndex: pageIndex
        )
    }

    /// Saves one JPEG per scan page, ordered by `pageIndex`.
    public func saveScanPages(
        _ pages: [(data: Data, displayName: String)],
        sessionID: UUID
    ) throws -> [SessionSourceAsset] {
        try pages.enumerated().map { index, page in
            try saveData(
                page.data,
                sessionID: sessionID,
                fileName: "page-\(index + 1).jpg",
                displayName: page.displayName,
                kind: .multiPageScan,
                pageIndex: index
            )
        }
    }

    public func deleteSources(for sessionID: UUID) throws {
        let directory = sessionSourcesDirectory(sessionID: sessionID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            throw SessionSourceStoreError.ioFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func ensureSessionDirectory(sessionID: UUID) throws {
        let directory = sessionSourcesDirectory(sessionID: sessionID)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SessionSourceStoreError.ioFailed(error.localizedDescription)
        }
    }

    private func uniqueFileName(prefix: String, ext: String, sessionID: UUID) -> String {
        let base = prefix.isEmpty ? "source" : prefix
        let directory = sessionSourcesDirectory(sessionID: sessionID)
        var candidate = "\(base).\(ext)"
        var counter = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func sanitizedBaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutExt = (trimmed as NSString).deletingPathExtension
        let cleaned = withoutExt
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "source" : cleaned
    }

    private func sanitizedFileName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func defaultExtension(for kind: SessionSourceKind) -> String {
        switch kind {
        case .audio: return "m4a"
        case .pdf: return "pdf"
        case .image, .multiPageScan: return "jpg"
        case .plainText: return "txt"
        }
    }
}
