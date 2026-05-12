import Foundation

/// User-created folder for grouping entries (Voice Memos–style). Stored in the main sessions envelope.
public struct SessionFolder: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    /// Cached JSON for a folder-scoped health summary (`GlobalSummaryPayload` shape in the app).
    public var cachedSummaryJSON: String?
    public var cachedSummaryBackend: String?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        cachedSummaryJSON: String? = nil,
        cachedSummaryBackend: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.cachedSummaryJSON = cachedSummaryJSON
        self.cachedSummaryBackend = cachedSummaryBackend
    }
}
