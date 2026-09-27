import Foundation

public enum SummaryAdmission: String, Codable, Sendable { case supported, sourceLinked, sourceOnly, superseded }
public enum ClinicalFactTrust: String, Codable, Sendable { case verified, patientConfirmed, reviewRequired }
public struct SummaryCitation: Codable, Hashable, Sendable {
    public var field: String
    public var excerpt: String
    public init(field: String, excerpt: String) { self.field = field; self.excerpt = excerpt }
}
public struct SummaryAssessment: Codable, Hashable, Sendable {
    public var admission: SummaryAdmission
    public var reason: String
    public var sourceHash: String
    public var contentHash: String
    public var version: Int
    public var citations: [SummaryCitation]
    public var modelSupported: Bool?
    public init(admission: SummaryAdmission, reason: String, sourceHash: String, contentHash: String, citations: [SummaryCitation]) {
        self.admission = admission; self.reason = reason; self.sourceHash = sourceHash
        self.contentHash = contentHash; self.citations = citations; self.version = SummaryVerification.version
    }
}
public struct SummaryRun: Codable, Hashable, Sendable {
    public enum Stage: String, Codable, Sendable { case fetching, drafting, checking, reverifying, complete, interrupted, failed }
    public var id: UUID
    public var sourceHash: String
    public var stage: Stage
    public var version: Int
    public var updatedAt: Date
    public var completedSourceChunks: Int?
    public var promptVersion: String?
    public init(source: String, stage: Stage = .fetching) {
        id = UUID(); sourceHash = SummaryVerification.hash(source); self.stage = stage
        version = SummaryVerification.version; updatedAt = Date()
        completedSourceChunks = 0; promptVersion = "clinical-pipeline-v1"
    }
}
public struct SummaryRevision: Codable, Hashable, Sendable {
    public var runID: UUID
    public var date: Date
    public var entries: [SummaryEntry]
    public init(runID: UUID, entries: [SummaryEntry]) { self.runID = runID; date = Date(); self.entries = entries }
}
public struct SummaryCheck: Codable, Sendable {
    public var id: UUID
    public var supported: Bool
    public var reason: String
    public var citations: [SummaryCitation]
    public var exclusion: String?
    public var coreSupported: Bool?
    public var uncertainFields: [String]?
    public init(id: UUID, supported: Bool, reason: String, citations: [SummaryCitation], coreSupported: Bool? = nil, uncertainFields: [String]? = nil) {
        self.id = id; self.supported = supported; self.reason = reason; self.citations = citations
        self.coreSupported = coreSupported; self.uncertainFields = uncertainFields
    }
}
public enum SummaryVerification {
    // Recheck records affected by the checker request-schema routing regression.
    public static let version = 19
    public static func hash(_ value: String) -> String {
        var result: UInt64 = 14695981039346656037
        for byte in value.utf8 { result = (result ^ UInt64(byte)) &* 1099511628211 }
        return String(result, radix: 16)
    }
    /// Includes clinical content, not presentation identities or patient preferences.
    public static func contentHash(_ entry: SummaryEntry) -> String {
        var copy = entry
        copy.evidence?.assessment = nil; copy.evidence?.factIdentity = nil
        copy.evidence?.instructionIdentity = nil; copy.evidence?.combinationExcluded = nil
        copy.evidence?.combinationPrimary = nil
        copy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        copy.createdAt = .distantPast; copy.updatedAt = .distantPast
        copy.fields = copy.fields.map { var f = $0; f.id = copy.id; return f }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return hash(String(data: (try? encoder.encode(copy)) ?? Data(), encoding: .utf8) ?? "")
    }
    public static func isVisible(_ entry: SummaryEntry, source: String) -> Bool {
        isVisible(entry, sourceHash: hash(source))
    }
    public static func isVisible(_ entry: SummaryEntry, sourceHash: String) -> Bool {
        guard !entry.isDeleted else { return false }
        if entry.origin == .userAdded || entry.origin == .userEdited { return true }
        guard SummaryEntityStructure.exclusion(entry) == nil, let assessment = entry.evidence?.assessment else { return false }
        return [.supported, .sourceLinked].contains(assessment.admission) && assessment.sourceHash == sourceHash
            && assessment.contentHash == contentHash(entry)
    }

    /// Eligibility is distinct from confirmation: source-linked observations may inform
    /// descriptive concerns without becoming manually or clinically verified.
    public static func isPortraitEligible(_ entry: SummaryEntry, source: String) -> Bool {
        isPortraitEligible(entry, sourceHash: hash(source))
    }
    public static func isPortraitEligible(_ entry: SummaryEntry, sourceHash: String) -> Bool {
        isVisible(entry, sourceHash: sourceHash)
    }
    public static func trust(of entry: SummaryEntry, sourceHash: String) -> ClinicalFactTrust {
        guard !entry.isDeleted else { return .reviewRequired }
        // Patient confirmation is provenance, not clinician confirmation.
        if entry.origin == .userAdded || entry.origin == .userEdited { return .patientConfirmed }
        guard SummaryEntityStructure.exclusion(entry) == nil,
              let assessment = entry.evidence?.assessment,
              assessment.admission == .supported,
              assessment.sourceHash == sourceHash,
              assessment.contentHash == contentHash(entry) else { return .reviewRequired }
        return .verified
    }
    /// Patient-facing inclusion is distinct from strict automated verification.
    public static func sourceLinked(_ entry: SummaryEntry, source: String, evidence: String, exclusion: String? = nil) -> SummaryEntry {
        var result = entry
        if entry.origin == .userAdded || entry.origin == .userEdited { return result }
        let title = entry.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let administrative = ["health information is private", "share your confidential", "table of contents", "privacy notice", "partial exam", "attachment styles overview", "four attachment styles"]
        let blockers = ["wrong_patient", "contradicted", "not_patient_information", "unreadable"]
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !["the", "and", "of", "in", "a", "dr", "panel"].contains($0) }
        let originalWords = Set(source.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let ownExcerpt = entry.supportingExcerpt.flatMap { matchingCitation($0, source: source) }
        let attributed = entry.details.lowercased().range(of: #"\b(?:patient|person|i) (?:reports?|describes?|states?|reported|described|stated)\b"#, options: .regularExpression) != nil
        let narrativeCategory = [SummaryEntryCategory.chiefComplaint, .symptoms, .findings, .biopsychosocialContext].contains(entry.category)
        // An attributed paraphrase may use words absent from speech, but must retain
        // a concrete source quote and a meaningful shared subject. This is not verification.
        let subjectWords = words.filter { !["patient", "reported", "reports", "ongoing", "persistent", "condition", "problem", "history", "care", "health"].contains($0) }
        let excerptWords = Set((ownExcerpt ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let quotedReport = narrativeCategory && attributed && ownExcerpt != nil && subjectWords.contains { excerptWords.contains($0) }
        let anchored = (!words.isEmpty && words.allSatisfy { originalWords.contains($0) }) || quotedReport
        let excluded = SummaryEntityStructure.exclusion(entry) != nil || blockers.contains(exclusion ?? "") || administrative.contains(where: { title.contains($0) }) || !anchored
        if result.evidence == nil { result.evidence = ClinicalEvidence() }
        let reason = SummaryEntityStructure.exclusion(entry) ?? (excluded ? "This detail could not be linked to relevant information in the original." : "Added from your record. Automated checking is incomplete; you can edit or delete this detail.")
        result.needsReview = true
        result.reviewReason = reason
        result.evidence?.reviewReason = reason
        let excerpt = ownExcerpt ?? matchingCitation(evidence, source: source)
        result.sourceExcerpt = excerpt
        result.evidence?.assessment = nil
        let fingerprint = contentHash(result)
        result.evidence?.assessment = SummaryAssessment(admission: excluded ? .sourceOnly : .sourceLinked, reason: reason,
            sourceHash: hash(source), contentHash: fingerprint, citations: excerpt.map { [.init(field: "source", excerpt: $0)] } ?? [])
        return result
    }

    public static func requiredFields(_ entry: SummaryEntry) -> Set<String> {
        var fields: Set<String> = ["title"]
        if !entry.details.isEmpty { fields.insert("details") }
        for field in entry.fields where !field.value.isEmpty { fields.insert("field:" + field.label) }
        let e = entry.evidence
        let extras: [(String,String?)] = [("eventDate",e?.eventDate),("practitioner",e?.practitioner),
            ("assessmentMethod",e?.assessmentMethod),("dose",e?.dose),("frequency",e?.frequency),
            ("reasonStarted",e?.reasonStarted),("reasonStopped",e?.reasonStopped),("actionKind",e?.actionKind)]
        for (key,value) in extras where value?.isEmpty == false { fields.insert(key) }
        if e?.page != nil { fields.insert("sourcePage") }
        if e?.careInstruction != nil { fields.insert("careInstruction") }
        if e?.topicNames?.isEmpty == false { fields.insert("topicNames") }
        if e?.bodySystem?.isEmpty == false { fields.insert("bodySystem") }
        if e?.statusExplicit == true { fields.insert("clinicalStatus") }
        return fields
    }
    /// Field aliases describe duplicate storage, not semantic similarity. Unequal values never share evidence.
    private static func fieldIdentity(_ field: String) -> String {
        field.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private static func fieldValue(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func coveredFields(_ entry: SummaryEntry, citations: [SummaryCitation]) -> Set<String> {
        let required = requiredFields(entry)
        let supplied = Set(citations.map { fieldIdentity($0.field) })
        var covered = Set(required.filter { supplied.contains(fieldIdentity($0)) })
        let e = entry.evidence
        let values: [(String, String?)] = [("title",entry.title), ("details",entry.details),
            ("eventDate",e?.eventDate), ("practitioner",e?.practitioner), ("assessmentMethod",e?.assessmentMethod),
            ("dose",e?.dose), ("frequency",e?.frequency), ("reasonStarted",e?.reasonStarted), ("reasonStopped",e?.reasonStopped),
            ("actionKind",e?.actionKind), ("bodySystem",e?.bodySystem)]
        for field in entry.fields where !field.value.isEmpty {
            let key = "field:" + field.label
            // Models sometimes omit the field: prefix. Only accept an unambiguous label.
            let label = fieldIdentity(field.label)
            let matching = values.filter { fieldIdentity($0.0) == label && $0.1?.isEmpty == false }
            if supplied.contains(label), matching.isEmpty,
               entry.fields.filter({ fieldIdentity($0.label) == label }).count == 1 { covered.insert(key) }
            for (name, value) in values {
                guard let value, !value.isEmpty, fieldValue(value) == fieldValue(field.value),
                      fieldIdentity(name) == label || (name == "title" && label == "name") else { continue }
                if covered.contains(name) { covered.insert(key) }
                if covered.contains(key) { covered.insert(name) }
            }
        }
        return covered
    }

    /// Recover the actual original excerpt, allowing line wrapping/whitespace changes only.
    public static func matchingCitation(_ excerpt: String, source: String) -> String? {
        let words = excerpt.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range, in: source) else { return nil }
        return String(source[range])
    }

    /// Fail closed on meaning; presentation duplicates do not require duplicate citations.
    public static func assess(_ entry: SummaryEntry, check: SummaryCheck?, source: String) -> SummaryEntry {
        var entry = entry
        let citations = check?.citations ?? []
        let valid = citations.compactMap { citation -> SummaryCitation? in
            guard let excerpt = matchingCitation(citation.excerpt, source: source) else { return nil }
            return SummaryCitation(field: citation.field, excerpt: excerpt)
        }
        let missing = requiredFields(entry).subtracting(coveredFields(entry, citations: valid)).sorted()
        let uncertain = Set((check?.uncertainFields ?? []).flatMap { value -> [String] in
            let key = fieldIdentity(value)
            return key.hasPrefix("field") ? [key, String(key.dropFirst(5))] : [key, "field" + key]
        })
        let uncertainPopulated = requiredFields(entry).filter { uncertain.contains(fieldIdentity($0)) }.sorted()
        let conflictingLabels = Dictionary(grouping: entry.fields.filter { !$0.value.isEmpty }, by: { fieldIdentity($0.label) })
            .values.filter { Set($0.map { fieldValue($0.value) }).count > 1 }.compactMap { $0.first?.label }.sorted()
        let reason: String?
        if check?.id != entry.id { reason = "The source check did not return a decision for this detail. Regenerate the summary to retry." }
        else if check?.supported != true { reason = check?.reason.isEmpty == false ? check!.reason : "The source does not clearly support this detail." }
        else if entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reason = "This detail has no clear title." }
        else if !uncertainPopulated.isEmpty { reason = "The source check still identifies uncertain fields: " + uncertainPopulated.joined(separator: ", ") + "." }
        else if !conflictingLabels.isEmpty { reason = "This detail contains conflicting values for: " + conflictingLabels.joined(separator: ", ") + "." }
        else if !validContactFields(entry) { reason = "Contact information could not be separated into valid fields." }
        else if !missing.isEmpty {
            let labels = missing.map { $0.replacingOccurrences(of: "field:", with: "") }.joined(separator: ", ")
            reason = "The checker considered this detail supported, but usable source evidence was missing for: \(labels). Regenerate the summary to retry."
        } else { reason = nil }
        if entry.evidence == nil { entry.evidence = ClinicalEvidence() }
        let fingerprint = contentHash(entry)
        entry.evidence?.assessment = SummaryAssessment(admission: reason == nil ? .supported : .sourceOnly,
            reason: reason ?? "Supported by original source", sourceHash: hash(source), contentHash: fingerprint, citations: valid)
        entry.evidence?.assessment?.modelSupported = check?.supported
        return entry
    }

    /// Retain an explicitly verified standalone medication/contact identity, not an unsupported clinical interpretation.
    /// This only proposes a correction: the reduced entry MUST pass a fresh independent check before publication.
    public static func supportedCoreForRechecking(_ entry: SummaryEntry, check: SummaryCheck?, source: String) -> SummaryEntry? {
        guard [.medications, .practitionerContact].contains(entry.category), let check,
              check.id == entry.id, check.coreSupported == true else { return nil }
        let valid = check.citations.filter { matchingCitation($0.excerpt, source: source) != nil }
        let covered = coveredFields(entry, citations: valid)
        let uncertain = Set((check.uncertainFields ?? []).flatMap { value -> [String] in
            let key = fieldIdentity(value)
            return key.hasPrefix("field") ? [key, String(key.dropFirst(5))] : [key, "field" + key]
        })
        guard covered.contains("title"), !uncertain.contains("title") else { return nil }
        func keep(_ field: String) -> Bool { covered.contains(field) && !uncertain.contains(fieldIdentity(field)) }
        var reduced = entry
        if !keep("details") { reduced.details = "" }
        reduced.fields.removeAll { !keep("field:" + $0.label) || uncertain.contains(fieldIdentity($0.label)) }
        if !keep("eventDate") { reduced.evidence?.eventDate = nil; reduced.relevantDate = nil; reduced.dateNeedsReview = true }
        if !keep("practitioner") { reduced.evidence?.practitioner = nil }
        if !keep("assessmentMethod") { reduced.evidence?.assessmentMethod = nil }
        if !keep("dose") { reduced.evidence?.dose = nil }
        if !keep("frequency") { reduced.evidence?.frequency = nil }
        if !keep("reasonStarted") { reduced.evidence?.reasonStarted = nil }
        if !keep("reasonStopped") { reduced.evidence?.reasonStopped = nil }
        if !keep("actionKind") { reduced.evidence?.actionKind = nil }
        if !keep("sourcePage") { reduced.evidence?.page = nil }
        if !keep("topicNames") { reduced.evidence?.topicNames = nil }
        if !keep("bodySystem") { reduced.evidence?.bodySystem = nil }
        if !keep("careInstruction") { reduced.evidence?.careInstruction = nil }
        if !keep("clinicalStatus") { reduced.evidence?.statusExplicit = false }
        reduced.evidence?.contactFields = entry.category == .practitionerContact ? reduced.fields : nil
        let removed = requiredFields(entry).subtracting(requiredFields(reduced)).sorted()
        guard !removed.isEmpty else { return nil }
        reduced.evidence?.omittedFields = Array(Set((entry.evidence?.omittedFields ?? []) + removed)).sorted()
        reduced.evidence?.reviewReason = "Some details were unclear in the original and have been left unset."
        reduced.evidence?.assessment = nil
        reduced.reviewReason = reduced.evidence?.reviewReason
        reduced.needsReview = true
        return reduced
    }

    public static func exclusionReason(_ entry: SummaryEntry, source: String) -> String {
        if let reason = SummaryEntityStructure.exclusion(entry) { return reason }
        guard let assessment = entry.evidence?.assessment else { return "Awaiting source checking" }
        if assessment.admission == .superseded { return "Replaced during source reassessment" }
        if assessment.sourceHash != hash(source) { return "The original text changed after this check. Regenerate the summary to check it again." }
        if assessment.admission == .supported {
            return "This detail changed after source checking. Regenerate the summary to check the saved version."
        }
        if assessment.version < 8 {
            return "This older check did not pass all evidence checks. Regenerate the summary to retry with the updated checker."
        }
        return assessment.reason
    }

    public static func validContactFields(_ entry: SummaryEntry) -> Bool {
        guard entry.category == .practitionerContact else { return true }
        return entry.fields.allSatisfy { field in
            guard !field.value.isEmpty else { return true }
            if field.label.lowercased() == "phone" {
                return field.value.filter(\.isNumber).count >= 7 && field.value.replacingOccurrences(of: "(?i)ext\\.?|x", with: "", options: .regularExpression).range(of: #"[A-Za-z]"#, options: .regularExpression) == nil
            }
            if field.label.lowercased() == "email" {
                return field.value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
            }
            guard field.label.lowercased() == "address" else { return true }
            return field.value.range(of: #"(?i)\b(address|org|organization|phone|email|role|specialty)\s*:"#, options: .regularExpression) == nil
        }
    }
}

public struct SummaryReview: Sendable {
    public var assessed: [SummaryEntry]
    public var corrections: [SummaryEntry]
    public init(assessed: [SummaryEntry], corrections: [SummaryEntry]) { self.assessed = assessed; self.corrections = corrections }
}

public enum SummaryReviewPipeline {
    /// No partial result escapes when either pass fails. Corrected/new assertions always receive a separate check.
    public static func run(draft: [SummaryEntry], review: ([SummaryEntry], Bool) async throws -> SummaryReview) async throws -> [SummaryEntry] {
        try Task.checkCancellation()
        let first = try await review(draft, true)
        try Task.checkCancellation()
        guard !first.corrections.isEmpty else { return first.assessed }
        let second = try await review(first.corrections, false)
        try Task.checkCancellation()
        let recheckedIDs = Set(second.assessed.map(\.id))
        return first.assessed.filter { !recheckedIDs.contains($0.id) } + second.assessed
    }
}

public extension Session {
    var needsSummaryVerification: Bool {
        processingState != .failed && processingState != .transcribing &&
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (extractionVersion != SummaryVerification.version || (summaryRun != nil && summaryRun?.stage != .complete))
    }
}

public extension SummaryEntry {
    /// Never substitute generated prose for an original-source quotation.
    var supportingExcerpt: String? {
        let citations = evidence?.assessment?.citations ?? []
        let quote = citations.first(where: { $0.field.lowercased() == "title" })?.excerpt
            ?? citations.first?.excerpt ?? evidence?.excerpt ?? sourceExcerpt
        return quote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? quote : nil
    }
}
