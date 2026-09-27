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
    private var cachedEnvelope: SessionsEnvelope?

    /// Root directory containing `sessions.json` and `sources/`.
    public var storageDirectory: URL { directoryURL }

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
        if let cachedEnvelope { return cachedEnvelope }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SessionsEnvelope(sessions: [], folders: [])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var envelope = try decoder.decode(SessionsEnvelope.self, from: data)
            guard envelope.version <= SessionsEnvelope.currentVersion else { throw SessionStoreError.decodingFailed }
            if envelope.version < SessionsEnvelope.currentVersion {
                let backup = directoryURL.appendingPathComponent("sessions-v\(envelope.version)-backup.json")
                if !fileManager.fileExists(atPath: backup.path) {
                    try data.write(to: backup, options: [.atomic])
                    guard try Data(contentsOf: backup) == data else { throw SessionStoreError.ioFailed("Could not verify the backup.") }
                }
                for i in envelope.sessions.indices {
                    guard var entries = envelope.sessions[i].summaryEntries else { continue }
                    for j in entries.indices where entries[j].origin == .generated || entries[j].origin == .legacyImported {
                        // Old generated dates were upload dates, not validated clinical dates.
                        entries[j].relevantDate = nil
                        entries[j].dateNeedsReview = true
                        entries[j].sourceExcerpt = nil
                    }
                    envelope.sessions[i].summaryEntries = entries
                }
                try saveEnvelope(envelope)
                envelope.version = SessionsEnvelope.currentVersion
            }
            cachedEnvelope = envelope
            return envelope
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
        cachedEnvelope = env
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

    /// Removes the session with the given `id`, its source files, and saves.
    public func delete(id: UUID) throws {
        var env = try loadEnvelope()
        if let removed = env.sessions.first(where: { $0.id == id }) {
            invalidateFolderSummary(&env, folderID: removed.folderID)
        }
        env.sessions.removeAll { $0.id == id }
        try saveEnvelope(env)
        let sourceStore = SessionSourceStore(fileManager: fileManager, storageDirectory: directoryURL)
        try sourceStore.deleteSources(for: id)
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

    public func healthSnapshot() throws -> HealthMemorySnapshot {
        var env = try loadEnvelope()
        let protected = Set(env.preferences.map(\.id))
        var changed = false
        var keys = HealthFactKeyCache()
        for i in env.sessions.indices where !protected.isEmpty {
            guard var entries = env.sessions[i].summaryEntries else { continue }
            for j in entries.indices {
                let currentKey = keys.key(entries[j])
                let legacyKey = HealthMemoryProjection.legacyKey(for: entries[j])
                let key = protected.contains(currentKey) ? currentKey : legacyKey
                if protected.contains(key), entries[j].evidence?.factIdentity == nil, entries[j].evidence?.instructionIdentity == nil {
                    if entries[j].evidence == nil { entries[j].evidence = ClinicalEvidence() }
                    entries[j].evidence?.factIdentity = key; changed = true
                }
            }
            env.sessions[i].summaryEntries = entries
        }
        if changed { try saveEnvelope(env) }
        return HealthMemorySnapshot(sessions: env.sessions, folders: env.folders, topics: env.topics,
                                  careTeam: HealthFactMatching.displayContacts(env.careTeam), preferences: env.preferences, profile: env.profile)
    }

    /// Upgrade old implicit groups and link equivalent facts without deleting their occurrences.
    public func consolidateHealthFacts() throws {
        _ = try healthSnapshot() // Anchor existing choices before any identity changes.
        try consolidateCareInstructions()
        var env = try loadEnvelope()
        var changed = false
        let entries = env.sessions.flatMap { $0.summaryEntries ?? [] }.filter { !$0.isDeleted }
        var assignments: [UUID: String] = [:]
        var keys = HealthFactKeyCache()
        // Older versions trusted generated fact keys. Split incompatible legacy groups, carrying choices forward.
        for (key, group) in Dictionary(grouping: entries, by: { keys.key($0) }) {
            guard let first = group.first, !CareInstructionPresentation.applies(first),
                  !group.contains(where: { $0.evidence?.combinationPrimary == true || $0.evidence?.combinationExcluded == true || $0.origin == .userEdited || $0.origin == .userAdded }) else { continue }
            let partitions = Dictionary(grouping: group, by: HealthFactMatching.key)
            guard partitions.count > 1 else { continue }
            for (signature, members) in partitions {
                let identity = key + "|split|" + signature
                for member in members { assignments[member.id] = identity }
                if !env.preferences.contains(where: { $0.id == identity }), var preference = env.preferences.first(where: { $0.id == key }) {
                    preference.id = identity; preference.reviewedRevision = nil
                    env.preferences.append(preference)
                }
            }
        }
        func apply(_ identities: [UUID: String]) {
            for i in env.sessions.indices {
                guard var rows = env.sessions[i].summaryEntries else { continue }
                for j in rows.indices {
                    guard let id = identities[rows[j].id], rows[j].evidence?.factIdentity != id else { continue }
                    if rows[j].evidence == nil { rows[j].evidence = ClinicalEvidence() }
                    rows[j].evidence?.factIdentity = id; changed = true
                }
                env.sessions[i].summaryEntries = rows
            }
        }
        apply(assignments)
        let savedIDs = Set(env.preferences.map(\.id))
        let snapshot = HealthMemorySnapshot(sessions: env.sessions, topics: env.topics, preferences: env.preferences)
        // A display group may contain different prescription events or complementary
        // contacts. Persisting that group's ID onto every occurrence caused the next
        // consolidation to split them, then regroup them, endlessly changing identity.
        let facts = HealthMemoryProjection.facts(in: snapshot, includingHidden: true, verifiedOnly: false, groupHistoryForDisplay: false)
            .filter { !CareInstructionPresentation.applies($0.latest) }
        assignments = [:]
        for fact in facts where fact.occurrences.count > 1 {
            for entry in fact.occurrences { assignments[entry.id] = fact.id }
        }
        for bucket in Dictionary(grouping: facts, by: { HealthFactMatching.candidateKey($0.latest) }).values {
            let ordered = bucket.sorted {
                if savedIDs.contains($0.id) != savedIDs.contains($1.id) { return savedIDs.contains($0.id) }
                return $0.id < $1.id
            }
            var representatives: [HealthFact] = []
            for fact in ordered {
                if let root = representatives.first(where: { candidate in
                    HealthFactConsolidation.preferencesAgree(candidate, fact, savedIDs: savedIDs)
                    && fact.occurrences.allSatisfy { HealthFactMatching.equivalent(candidate.latest, $0) }
                    && candidate.occurrences.allSatisfy { HealthFactMatching.equivalent(fact.latest, $0) }
                }) {
                    for entry in root.occurrences + fact.occurrences { assignments[entry.id] = root.id }
                } else { representatives.append(fact) }
            }
        }
        apply(assignments)
        // Link extracted provider occurrences to compatible saved contacts, preventing two displayed copies.
        for i in env.careTeam.indices where env.careTeam[i].duplicateOf == nil && env.careTeam[i].combinationExcluded != true {
            let member = env.careTeam[i]
            for entry in entries where entry.category == .practitionerContact {
                if HealthFactMatching.contactsMatch(member, HealthFactMatching.contact(entry)),
                   !env.careTeam[i].sourceEntryIDs.contains(entry.id) {
                    env.careTeam[i].sourceEntryIDs.append(entry.id); changed = true
                }
            }
        }
        // Saved contacts retain their original rows; aliases are suppressed only in the displayed snapshot.
        var contactBuckets: [String: [Int]] = [:]
        for i in env.careTeam.indices where env.careTeam[i].duplicateOf == nil && env.careTeam[i].combinationExcluded != true {
            let member = env.careTeam[i]
            let key = HealthFactMatching.canonical(member.name)
            if let root = contactBuckets[key, default: []].first(where: { index in
                HealthFactMatching.contactsMatch(env.careTeam[index], member)
                && env.careTeam.filter { $0.duplicateOf == env.careTeam[index].id }.allSatisfy { HealthFactMatching.contactsCompatible($0, member) }
            }) {
                env.careTeam[i].duplicateOf = env.careTeam[root].id; changed = true
            } else { contactBuckets[key, default: []].append(i) }
        }
        if changed { try saveEnvelope(env) }
    }

    public func combineHealthFacts(keeping rootID: String, duplicateID: String) throws -> HealthCombinationUndo {
        var env = try loadEnvelope()
        let facts = HealthMemoryProjection.facts(in: .init(sessions: env.sessions, topics: env.topics, preferences: env.preferences), verifiedOnly: false)
        guard let root = facts.first(where: { $0.id == rootID }), let other = facts.first(where: { $0.id == duplicateID }),
              root.id != other.id, root.category == other.category, root.isAction == other.isAction else {
            throw SessionStoreError.ioFailed("Choose two details from the same category.")
        }
        if CareInstructionPresentation.applies(root.latest) {
            return .care(try combineCareInstructions(keeping: rootID, duplicateID: duplicateID))
        }
        let savedIDs = Set(env.preferences.map(\.id))
        guard HealthFactConsolidation.preferencesAgree(root, other, savedIDs: savedIDs),
              !other.preference.reminderEnabled,
              !savedIDs.contains(other.id) || savedIDs.contains(root.id) ||
                (other.preference.clinicalStatus == nil && other.preference.actionStatus == nil && other.preference.dueDate == nil && other.preference.topicIDs == nil) else {
            throw SessionStoreError.ioFailed("These details have different saved settings. Keep them separate, or make their settings agree before combining.")
        }
        var previous: [UUID: FactCombinationUndo.Identity] = [:]
        let ids = Set((root.occurrences + other.occurrences).map(\.id))
        for i in env.sessions.indices {
            guard var rows = env.sessions[i].summaryEntries else { continue }
            for j in rows.indices where ids.contains(rows[j].id) {
                previous[rows[j].id] = .init(key: HealthMemoryProjection.key(for: rows[j]), factIdentity: rows[j].evidence?.factIdentity, primary: rows[j].evidence?.combinationPrimary)
                if rows[j].evidence == nil { rows[j].evidence = ClinicalEvidence() }
                rows[j].evidence?.factIdentity = rootID
                let isPrimary = rows[j].id == root.latest.id
                rows[j].evidence?.combinationPrimary = isPrimary
            }
            env.sessions[i].summaryEntries = rows
        }
        try saveEnvelope(env)
        return .facts(.init(identities: previous, combinedID: rootID))
    }

    public func undoHealthCombination(_ undo: HealthCombinationUndo) throws {
        switch undo {
        case .care(let value): try undoCareCombination(value)
        case .facts(let value):
            var env = try loadEnvelope()
            for i in env.sessions.indices {
                guard var rows = env.sessions[i].summaryEntries else { continue }
                for j in rows.indices {
                    guard let previous = value.identities[rows[j].id] else { continue }
                    guard HealthMemoryProjection.key(for: rows[j]) == value.combinedID else {
                        throw SessionStoreError.ioFailed("These details have been combined again. Undo the most recent combination first.")
                    }
                    rows[j].evidence?.factIdentity = previous.factIdentity ?? previous.key
                    rows[j].evidence?.combinationPrimary = previous.primary
                    rows[j].evidence?.combinationExcluded = true
                }
                env.sessions[i].summaryEntries = rows
            }
            try saveEnvelope(env)
        case .contacts(let value):
            var env = try loadEnvelope()
            for original in value.members {
                if let i = env.careTeam.firstIndex(where: { $0.id == original.id }) {
                    env.careTeam[i].duplicateOf = original.duplicateOf
                    env.careTeam[i].combinationExcluded = true
                }
            }
            try saveEnvelope(env)
        }
    }

    /// Link duplicates without deleting occurrences or changing original records.
    public func consolidateCareInstructions() throws {
        var env = try loadEnvelope()
        let snapshot = HealthMemorySnapshot(sessions: env.sessions, preferences: env.preferences)
        let facts = HealthMemoryProjection.facts(in: snapshot, includingHidden: true, verifiedOnly: false)
            .filter { CareInstructionPresentation.applies($0.latest) }
        let checkedIDs = Set(env.sessions.flatMap { session in
            (session.summaryEntries ?? []).filter { $0.evidence?.assessment?.admission == .supported && SummaryVerification.isVisible($0, source: session.transcript) }
                .map(\.id)
        })
        let savedIDs = Set(env.preferences.map(\.id))
        var identities: [UUID: String] = [:]
        for bucket in Dictionary(grouping: facts, by: { HealthFactMatching.candidateKey($0.latest) }).values {
            // Prefer the existing patient identity so its reminder identifier and saved choices remain intact.
            let ordered = bucket.sorted {
                if savedIDs.contains($0.id) != savedIDs.contains($1.id) { return savedIDs.contains($0.id) }
                return $0.id < $1.id
            }
            var groups: [(root: HealthFact, entries: [SummaryEntry])] = []
            for fact in ordered {
                if let index = groups.firstIndex(where: { group in
                    HealthFactConsolidation.preferencesAgree(group.root, fact, savedIDs: savedIDs)
                    && group.entries.allSatisfy { a in fact.occurrences.allSatisfy { b in
                        CareInstructionPresentation.equivalent(a, b, allowDifferentEvidence: checkedIDs.contains(a.id) && checkedIDs.contains(b.id))
                    } }
                }) {
                    for entry in groups[index].entries + fact.occurrences { identities[entry.id] = groups[index].root.id }
                    groups[index].entries += fact.occurrences
                } else { groups.append((fact, fact.occurrences)) }
            }
        }
        var changed = false
        for i in env.sessions.indices {
            guard var entries = env.sessions[i].summaryEntries else { continue }
            for j in entries.indices {
                if let identity = identities[entries[j].id], entries[j].evidence?.instructionIdentity != identity {
                    if entries[j].evidence == nil { entries[j].evidence = ClinicalEvidence() }
                    entries[j].evidence?.instructionIdentity = identity; changed = true
                }
            }
            env.sessions[i].summaryEntries = entries
        }
        if changed { try saveEnvelope(env) }
    }

    public func combineCareInstructions(keeping rootID: String, duplicateID: String) throws -> CareCombinationUndo {
        var env = try loadEnvelope()
        let snapshot = HealthMemorySnapshot(sessions: env.sessions, preferences: env.preferences)
        let facts = HealthMemoryProjection.facts(in: snapshot, verifiedOnly: false)
        guard let root = facts.first(where: { $0.id == rootID }), let other = facts.first(where: { $0.id == duplicateID }),
              root.id != other.id, CareInstructionPresentation.applies(root.latest), root.category == other.category,
              root.isAction == other.isAction,
              !env.preferences.contains(where: { preference in
                  guard preference.id == other.id else { return false }
                  let kept = root.preference
                  return preference.reminderEnabled || preference.clinicalStatus != kept.clinicalStatus
                      || preference.actionStatus != kept.actionStatus || preference.dueDate != kept.dueDate
                      || preference.hidden != kept.hidden || preference.topicIDs != kept.topicIDs
                      || preference.reviewedRevision != kept.reviewedRevision
              }) else {
            throw SessionStoreError.ioFailed("This duplicate has saved edits or settings. Keep the instructions separate to preserve them.")
        }
        let ids = Set((root.occurrences + other.occurrences).map(\.id))
        var previous: [UUID: String] = [:], absent = Set<UUID>()
        for i in env.sessions.indices {
            guard var entries = env.sessions[i].summaryEntries else { continue }
            for j in entries.indices where ids.contains(entries[j].id) {
                if let old = entries[j].evidence?.instructionIdentity { previous[entries[j].id] = old }
                else { absent.insert(entries[j].id) }
                if entries[j].evidence == nil { entries[j].evidence = ClinicalEvidence() }
                entries[j].evidence?.instructionIdentity = rootID
            }
            env.sessions[i].summaryEntries = entries
        }
        try saveEnvelope(env)
        return CareCombinationUndo(identities: previous, absentIdentities: absent)
    }

    public func undoCareCombination(_ undo: CareCombinationUndo) throws {
        var env = try loadEnvelope()
        for i in env.sessions.indices {
            guard var entries = env.sessions[i].summaryEntries else { continue }
            for j in entries.indices where undo.identities[entries[j].id] != nil || undo.absentIdentities.contains(entries[j].id) {
                let previousIdentity = undo.identities[entries[j].id]
                entries[j].evidence?.instructionIdentity = previousIdentity
                entries[j].evidence?.combinationExcluded = true
            }
            env.sessions[i].summaryEntries = entries
        }
        try saveEnvelope(env)
    }

    public func saveTopic(_ topic: HealthTopic) throws {
        var env = try loadEnvelope()
        if let index = env.topics.firstIndex(where: { $0.id == topic.id }) { env.topics[index] = topic }
        else { env.topics.append(topic) }
        try saveEnvelope(env)
    }

    public func saveCareTeamMember(_ member: CareTeamMember) throws {
        var env = try loadEnvelope()
        if let index = env.careTeam.firstIndex(where: { $0.id == member.id }) { env.careTeam[index] = member }
        else { env.careTeam.append(member) }
        try saveEnvelope(env)
    }

    public func deleteCareTeamMember(id: UUID) throws {
        var env = try loadEnvelope()
        env.careTeam.removeAll { $0.id == id || $0.duplicateOf == id }
        try saveEnvelope(env)
    }

    public func combineCareTeamMembers(keeping rootID: UUID, duplicateID: UUID) throws -> HealthCombinationUndo {
        var env = try loadEnvelope()
        let displayed = HealthFactMatching.displayContacts(env.careTeam)
        guard rootID != duplicateID, let root = displayed.first(where: { $0.id == rootID }),
              let other = displayed.first(where: { $0.id == duplicateID }),
              HealthFactMatching.contactsCompatible(root, other) else {
            throw SessionStoreError.ioFailed("These contacts have conflicting contact details. Edit them before combining so no information is lost.")
        }
        let affected = env.careTeam.filter { $0.id == rootID || $0.id == duplicateID || $0.duplicateOf == rootID || $0.duplicateOf == duplicateID }
        for i in env.careTeam.indices where env.careTeam[i].id == duplicateID || env.careTeam[i].duplicateOf == duplicateID {
            env.careTeam[i].duplicateOf = rootID
        }
        try saveEnvelope(env)
        return .contacts(.init(members: affected, combinedID: rootID))
    }

    public func savePreference(_ preference: HealthFactPreference) throws {
        var env = try loadEnvelope()
        // Anchor patient decisions to their existing facts before a later extraction changes wording.
        for i in env.sessions.indices {
            guard var entries = env.sessions[i].summaryEntries else { continue }
            for j in entries.indices where HealthMemoryProjection.key(for: entries[j]) == preference.id && entries[j].evidence?.instructionIdentity == nil {
                if entries[j].evidence == nil { entries[j].evidence = ClinicalEvidence() }
                entries[j].evidence?.factIdentity = preference.id
            }
            env.sessions[i].summaryEntries = entries
        }
        if let index = env.preferences.firstIndex(where: { $0.id == preference.id }) { env.preferences[index] = preference }
        else { env.preferences.append(preference) }
        try saveEnvelope(env)
    }

    public func saveProfile(_ profile: PatientProfile) throws {
        var env = try loadEnvelope()
        env.profile = profile
        try saveEnvelope(env)
    }

    /// Patch one occurrence inside the actor; concurrent edits cannot overwrite each other's session snapshots.
    /// An old markdown-only summary becomes visible without requiring cloud processing.
    public func importLegacySummary(sessionID: UUID, expectedSummary: String, entries: [SummaryEntry]) throws {
        var env = try loadEnvelope()
        guard !entries.isEmpty, let index = env.sessions.firstIndex(where: { $0.id == sessionID }),
              env.sessions[index].summary == expectedSummary,
              env.sessions[index].summaryEntries?.isEmpty != false else { return }
        env.sessions[index].summaryEntries = entries
        try saveEnvelope(env)
    }

    public func saveSummaryEntry(_ entry: SummaryEntry) throws {
        var env = try loadEnvelope()
        guard let index = env.sessions.firstIndex(where: { $0.id == entry.sourceSessionID }) else {
            throw SessionStoreError.ioFailed("The original record is no longer available.")
        }
        var updated = entry
        if let previous = env.sessions[index].summaryEntries?.first(where: { $0.id == entry.id }), !CareInstructionPresentation.applies(previous) {
            let identity = HealthMemoryProjection.key(for: previous)
            for i in env.sessions.indices {
                guard var rows = env.sessions[i].summaryEntries else { continue }
                for j in rows.indices where HealthMemoryProjection.key(for: rows[j]) == identity {
                    if rows[j].evidence == nil { rows[j].evidence = ClinicalEvidence() }
                    rows[j].evidence?.factIdentity = identity
                }
                env.sessions[i].summaryEntries = rows
            }
            if updated.evidence == nil { updated.evidence = ClinicalEvidence() }
            updated.evidence?.factIdentity = identity
        }
        var entries = env.sessions[index].summaryEntries ?? []
        if let i = entries.firstIndex(where: { $0.id == updated.id }) { entries[i] = updated }
        else { entries.append(updated) }
        env.sessions[index].summaryEntries = entries
        invalidateFolderSummary(&env, folderID: env.sessions[index].folderID)
        try saveEnvelope(env)
    }

    public func verifiedPairDecision(_ key: String) throws -> Bool? { try loadEnvelope().verifiedPairDecisions[key] }

    public func saveVerifiedPairDecision(_ key: String, equivalent: Bool, root: HealthFact, other: HealthFact) throws {
        var env = try loadEnvelope()
        let snapshot = HealthMemorySnapshot(sessions: env.sessions, preferences: env.preferences)
        let facts = HealthMemoryProjection.facts(in: snapshot, verifiedOnly: true)
        guard let a = facts.first(where: { $0.id == root.id }), let b = facts.first(where: { $0.id == other.id }),
              a.revision == root.revision, b.revision == other.revision,
              (a.occurrences + b.occurrences).allSatisfy({ $0.evidence?.combinationExcluded != true }) else { return }
        if equivalent {
            // Reuse the patient-preference guards and preserve every original occurrence.
            // A conflict is a valid reason to retain separate cards, not to retry the model forever.
            _ = try? combineHealthFacts(keeping: a.id, duplicateID: b.id)
            env = try loadEnvelope()
        }
        env.verifiedPairDecisions[key] = equivalent
        try saveEnvelope(env)
    }

    /// A durable run token prevents stale or overlapping extraction from publishing.
    public func beginSummaryRun(sessionID: UUID, expected: Session) throws -> SummaryRun {
        var env = try loadEnvelope()
        guard let i = env.sessions.firstIndex(where: { $0.id == sessionID }),
              env.sessions[i].transcript == expected.transcript else { throw SummaryCommitError.sourceChanged }
        if var existing = env.sessions[i].summaryRun,
           existing.stage != .complete,
           existing.sourceHash == SummaryVerification.hash(expected.transcript),
           existing.version == SummaryVerification.version,
           existing.promptVersion == "clinical-pipeline-v1",
           env.sessions[i].summaryDrafts != nil {
            existing.stage = .fetching
            existing.updatedAt = Date()
            env.sessions[i].summaryRun = existing
            try saveEnvelope(env)
            return existing
        }
        let run = SummaryRun(source: expected.transcript)
        env.sessions[i].summaryRun = run
        env.sessions[i].summaryDrafts = []
        try saveEnvelope(env)
        return run
    }

    public func summaryDrafts(sessionID: UUID, runID: UUID) throws -> [SummaryEntry] {
        let env = try loadEnvelope()
        guard let session = env.sessions.first(where: { $0.id == sessionID }), session.summaryRun?.id == runID,
              session.summaryRun?.sourceHash == SummaryVerification.hash(session.transcript) else { throw SummaryCommitError.sourceChanged }
        return session.summaryDrafts ?? []
    }

    public func checkpointSummaryDraft(sessionID: UUID, runID: UUID, entries: [SummaryEntry],
                                       completedSourceChunks: Int? = nil) throws {
        var env = try loadEnvelope()
        guard let i = env.sessions.firstIndex(where: { $0.id == sessionID }), env.sessions[i].summaryRun?.id == runID,
              env.sessions[i].summaryRun?.sourceHash == SummaryVerification.hash(env.sessions[i].transcript) else { throw SummaryCommitError.sourceChanged }
        env.sessions[i].summaryDrafts = entries
        if let completedSourceChunks {
            let previous = env.sessions[i].summaryRun?.completedSourceChunks ?? 0
            env.sessions[i].summaryRun?.completedSourceChunks = max(previous, completedSourceChunks)
        }
        env.sessions[i].summaryRun?.updatedAt = Date()
        try saveEnvelope(env)
    }

    public func updateSummaryRun(sessionID: UUID, runID: UUID, stage: SummaryRun.Stage) throws {
        var env = try loadEnvelope()
        guard let i = env.sessions.firstIndex(where: { $0.id == sessionID }), env.sessions[i].summaryRun?.id == runID else { return }
        env.sessions[i].summaryRun?.stage = stage
        env.sessions[i].summaryRun?.updatedAt = Date()
        try saveEnvelope(env)
    }

    public func publishVerifiedSummary(expected: Session, runID: UUID, entries: [SummaryEntry]) throws {
        _ = try healthSnapshot()
        var env = try loadEnvelope()
        guard let i = env.sessions.firstIndex(where: { $0.id == expected.id }),
              env.sessions[i].summaryRun?.id == runID,
              env.sessions[i].transcript == expected.transcript else { throw SummaryCommitError.sourceChanged }
        let previous = env.sessions[i].summaryEntries ?? []
        // Compare patient edits rather than identities, which may have been anchored during refresh.
        let edits = { (entries: [SummaryEntry]) in entries.filter { $0.origin == .userAdded || $0.origin == .userEdited || $0.isDeleted } }
        guard edits(previous) == edits(expected.summaryEntries ?? []) else { throw SummaryCommitError.patientChanged }
        guard entries.allSatisfy({ $0.evidence?.assessment?.sourceHash == SummaryVerification.hash(expected.transcript) }) else {
            throw SummaryCommitError.sourceChanged
        }
        let merged = SummaryEntryMerge.merging(generated: entries, existing: previous, supersedeUnmatchedGenerated: true)
        // Reconciliation keeps stable IDs; content hashes deliberately exclude those IDs.
        env.sessions[i].summaryRevisions = (env.sessions[i].summaryRevisions ?? []) + [SummaryRevision(runID: runID, entries: previous)]
        env.sessions[i].summaryEntries = merged
        env.sessions[i].summaryDrafts = nil
        env.sessions[i].title = env.sessions[i].displayTitle
        let visible = merged.filter { SummaryVerification.isVisible($0, source: expected.transcript) }
        env.sessions[i].summary = SummaryEntryCategory.allCases.compactMap { category in
            let rows = visible.filter { $0.category == category }
            return rows.isEmpty ? nil : "## \(category.displayTitle)\n" + rows.map { "- \($0.title)\($0.details.isEmpty ? "" : ": " + $0.details)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        env.sessions[i].extractionVersion = SummaryVerification.version
        env.sessions[i].summaryRun?.stage = .complete
        env.sessions[i].summaryRun?.updatedAt = Date()
        invalidateFolderSummary(&env, folderID: env.sessions[i].folderID)
        try saveEnvelope(env)
    }

    /// Merge generated data against the latest saved edits, never the view's stale copy.
    public func applyExtraction(sessionID: UUID, transcript: String, title: String, summary: String, entries: [SummaryEntry], version: Int) throws {
        _ = try healthSnapshot() // Anchor preferences from older saved files before replacing generated entries.
        var env = try loadEnvelope()
        guard let index = env.sessions.firstIndex(where: { $0.id == sessionID }), env.sessions[index].transcript == transcript else { return }
        env.sessions[index].summary = summary
        env.sessions[index].title = title
        env.sessions[index].summaryEntries = SummaryEntryMerge.merging(generated: entries, existing: env.sessions[index].summaryEntries)
        env.sessions[index].extractionVersion = version
        // Only explicit topic links from the source enter the topic list. No keyword association.
        for entry in entries {
            for name in entry.evidence?.topicNames ?? [] where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !env.topics.contains(where: { HealthMemoryProjection.normalize($0.name) == HealthMemoryProjection.normalize(name) }) {
                    env.topics.append(HealthTopic(name: name, bodySystem: entry.evidence?.bodySystem ?? ""))
                }
            }
        }
        invalidateFolderSummary(&env, folderID: env.sessions[index].folderID)
        try saveEnvelope(env)
    }

    public func moveSession(id: UUID, to folderID: UUID?) throws {
        var env = try loadEnvelope()
        guard let index = env.sessions.firstIndex(where: { $0.id == id }) else { return }
        invalidateFolderSummary(&env, folderID: env.sessions[index].folderID)
        env.sessions[index].folderID = folderID
        invalidateFolderSummary(&env, folderID: folderID)
        try saveEnvelope(env)
    }

    public func updateTranscript(sessionID: UUID, transcript: String?, error: String?) throws {
        var env = try loadEnvelope()
        guard let index = env.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let transcript {
            env.sessions[index].transcript = transcript
            env.sessions[index].extractionVersion = nil
        }
        env.sessions[index].processingState = error == nil ? .ready : .failed
        env.sessions[index].processingError = error
        try saveEnvelope(env)
    }

    private func atomicWrite(_ data: Data) throws {
        let tempURL = directoryURL.appendingPathComponent("\(Self.sessionsFileName).tmp", isDirectory: false)
        do {
            #if os(iOS)
            try data.write(to: tempURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: tempURL, options: [.atomic])
            #endif
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

public enum SummaryCommitError: LocalizedError {
    case sourceChanged, patientChanged
    public var errorDescription: String? {
        switch self {
        case .sourceChanged: return "The original changed while its summary was being checked. Please retry."
        case .patientChanged: return "Your edits were saved. Please retry the summary so it includes those changes."
        }
    }
}
