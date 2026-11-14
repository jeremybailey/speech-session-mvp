import Foundation

/// User-created folder for grouping entries (Voice Memos–style). Stored in the main sessions envelope.
public struct SessionFolder: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var conditionID: String?
    public var bodySystem: String?
    public var isDeleted: Bool?
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

/// Computed only from the saved publication and patient choices.
public struct RecordFolderLibrary: Sendable {
    public let folders: [SessionFolder]
    /// Includes empty automatic conditions so a patient can file a record back into one.
    public let selectableFolders: [SessionFolder]
    public let recordIDs: [UUID: Set<UUID>]
    public let memberships: [UUID: Set<UUID>]

    public init(snapshot: HealthMemorySnapshot, conditions: [ConditionSummary]) {
        var catalog = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        let liveIDs = Set(snapshot.sessions.map(\.id))
        var owners: [UUID: Set<UUID>] = [:]
        for session in snapshot.sessions {
            for entry in session.summaryEntries ?? [] where !entry.isDeleted {
                owners[entry.id, default: []].insert(session.id)
            }
        }
        var automatic: [UUID: Set<UUID>] = [:]
        let eligible = conditions.filter(ConditionSummaryProjection.isNavigationEligible)
        let destinations = Self.automaticDestinations(for: eligible, saved: catalog)
        for condition in eligible {
            let records = Set(condition.facts.flatMap { fact in
                fact.occurrences.compactMap { entry -> UUID? in
                    if fact.preference.topicIDs == nil &&
                        Self.exclusionOnly(entry: entry, condition: condition.name) { return nil }
                    if let source = entry.sourceSessionID, liveIDs.contains(source) { return source }
                    // Imported occurrences can retain an old source ID. Recover only an exact, unique owner.
                    guard let candidates = owners[entry.id], candidates.count == 1 else { return nil }
                    return candidates.first
                }
            })
            guard !records.isEmpty else { continue }
            let destination = destinations[condition.id] ?? (condition.id, HealthStoryText.displayName(condition.name))
            let id = IncrementalRecordUpdate.stableID("story-folder:" + destination.0)
            if catalog[id] == nil {
                var folder = SessionFolder(id: id, name: destination.1,
                                           createdAt: Date(timeIntervalSince1970: 0))
                folder.conditionID = destination.0
                folder.bodySystem = HealthAreaKind.classify(condition).rawValue
                catalog[id] = folder
            }
            for record in records { automatic[record, default: []].insert(id) }
        }
        // Suppress a generic care label only on records already indexed by a
        // specific condition in that same body system. Keep patient-owned folders.
        let generic = Set(catalog.values.filter { folder in
            folder.conditionID != nil && Self.isGenericCareLabel(folder.name) && !snapshot.folders.contains(where: { $0.id == folder.id })
        }.map(\.id))
        for (record, ids) in automatic {
            let active = ids.compactMap { catalog[$0] }.filter { $0.isDeleted != true }
            for folder in active where generic.contains(folder.id) && Self.isGenericCareLabel(folder.name) {
                if let system = folder.bodySystem, system != HealthAreaKind.other.rawValue,
                   active.contains(where: { $0.bodySystem == system && !Self.isGenericCareLabel($0.name) }) {
                    automatic[record]?.remove(folder.id)
                }
            }
        }
        let ordered = catalog.values.filter { $0.isDeleted != true }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        let visible = Set(ordered.map(\.id))
        var members: [UUID: Set<UUID>] = [:]
        var filed: [UUID: Set<UUID>] = [:]
        for record in snapshot.sessions {
            let selection = record.selectedFolderIDs ?? record.folderID.map { Set([$0]) } ?? automatic[record.id] ?? []
            filed[record.id] = selection.intersection(visible)
            for id in filed[record.id] ?? [] { members[id, default: []].insert(record.id) }
        }
        selectableFolders = ordered
        folders = ordered.filter { $0.conditionID == nil || members[$0.id]?.isEmpty == false }
        recordIDs = members
        memberships = filed
    }

    // These are filing labels. The clinical facts, including each lab measurement,
    // its date and its status, keep their original source and wording.
    private static func isGenericCareLabel(_ name: String) -> Bool {
        ConditionSummaryProjection.normalized(name).hasSuffix(" care condition")
    }

    private static func automaticDestinations(
        for conditions: [ConditionSummary], saved: [UUID: SessionFolder]
    ) -> [String: (String, String)] {
        func key(_ name: String) -> String {
            ConditionSummaryProjection.conditionKey(name)
                .replacingOccurrences(of: "cornea eye injury", with: "corneal injury")
        }
        var result: [String: (String, String)] = [:]
        let lipids: Set<String> = ["elevated ldl cholesterol", "elevated non hdl cholesterol", "elevated total cholesterol"]
        for condition in conditions {
            let originalID = IncrementalRecordUpdate.stableID("story-folder:" + condition.id)
            guard saved[originalID] == nil,
                  !condition.facts.contains(where: { $0.preference.topicIDs != nil }) else { continue }
            let name = key(condition.name)
            // Reuse the existing singular folder ID so its saved edits still apply.
            if name == "dry eyes" {
                let singular = conditions.filter { key($0.name) == "dry eye" && $0.bodySystem == condition.bodySystem }
                if singular.count == 1, let target = singular.first {
                    result[condition.id] = (target.id, HealthStoryText.displayName(target.name))
                    continue
                }
            }
            if lipids.contains(name) {
                result[condition.id] = ("lab-group:elevated-cholesterol", "Elevated cholesterol")
                continue
            }
            // Fold an exact component into a single existing compound heading.
            // Sharing a body system alone never establishes a relationship.
            let parents = conditions.filter { other in
                guard other.id != condition.id,
                      HealthAreaKind.classify(other) == HealthAreaKind.classify(condition) else { return false }
                let parts = key(other.name).components(separatedBy: " and ")
                return parts.count > 1 && parts.contains(name)
            }
            if parents.count == 1, let parent = parents.first {
                result[condition.id] = (parent.id, HealthStoryText.displayName(parent.name))
            }
        }
        // A singular label may already file into a compound condition.
        for (id, target) in result {
            if let parent = result[target.0] { result[id] = parent }
        }
        return result
    }

    private static func exclusionOnly(entry: SummaryEntry, condition: String) -> Bool {
        let normalize = ConditionSummaryProjection.normalized
        let normalizedName = normalize(condition)
        if normalizedName.hasSuffix(" ruled out") || normalizedName.hasPrefix("rule out ") ||
            normalizedName.hasPrefix("screening for ") || normalizedName.hasPrefix("no evidence of ") {
            return true
        }
        let name = NSRegularExpression.escapedPattern(for: normalizedName)
        let expressions = [
            "^(?:the clinical history (?:states|says) (?:to )?|(?:plan|planned|investigation) (?:to )?|to )?(?:rule out|r o) " + name + "$",
            "^" + name + " (?:was |is |has been |had been )?(?:to be )?(?:ruled out|excluded)$",
            "^(?:no evidence of|negative for|screening for|evaluation for|investigation for) " + name + "$",
            "^(?:history of )?" + name + " evaluation (?:was |is )?ruled out$"
        ]
        let assertions = [entry.title, entry.details, entry.supportingExcerpt ?? ""].map(normalize)
        return assertions.contains { text in expressions.contains { text.range(of: $0, options: .regularExpression) != nil } }
    }
}

extension SessionStore {
    /// Materialize selected automatic folders in the same transaction as the override.
    public func setRecordFolders(recordID: UUID, folders: [SessionFolder]) throws {
        var env = try loadEnvelope()
        guard let index = env.sessions.firstIndex(where: { $0.id == recordID }) else {
            throw SessionStoreError.ioFailed("This record is no longer available.")
        }
        for folder in folders {
            if let existing = env.folders.first(where: { $0.id == folder.id }) {
                guard existing.isDeleted != true else { throw SessionStoreError.ioFailed("A selected folder was deleted.") }
            } else {
                env.folders.append(folder)
            }
        }
        env.sessions[index].selectedFolderIDs = Set(folders.map(\.id))
        env.sessions[index].folderID = nil
        try saveEnvelope(env)
    }

    /// Soft deletion makes automatic-folder suppression and Undo survive a backup.
    public func setRecordFolderDeleted(_ deleted: Bool, folder: SessionFolder) throws {
        var env = try loadEnvelope()
        var updated = env.folders.first { $0.id == folder.id } ?? folder
        updated.isDeleted = deleted
        env.folders.removeAll { $0.id == folder.id }
        env.folders.append(updated)
        try saveEnvelope(env)
    }
}
