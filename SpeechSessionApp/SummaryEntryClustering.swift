import Foundation
import SpeechSessionPersistence

// MARK: - Cluster key (all summary categories)

/// Display-only identity for stacking same-named clinical facts across sources.
enum SummaryEntryClusterKey {
    /// Normalized key used to group entries. Empty titles do not stack together.
    static func key(for entry: SummaryEntry) -> String? {
        if let factKey = SummaryEntry.normalizedFactKey(entry.factKey) {
            return "\(entry.category.rawValue)|fact:\(factKey)"
        }
        let titleKey = clusterStem(from: entry.title, category: entry.category)
        guard !titleKey.isEmpty else { return nil }
        // Chief complaints also partition by body system so Neurological vs Other "pain" stay apart.
        if entry.category == .chiefComplaint {
            let system = BodySystem.resolved(for: entry).rawValue
            return "\(entry.category.rawValue)|\(system)|\(titleKey)"
        }
        return "\(entry.category.rawValue)|\(titleKey)"
    }

    /// Prefer a descriptive label for headers (not the ultra-short stem).
    static func displayTitle(for entries: [SummaryEntry]) -> String {
        let candidates = entries
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Prefer the longest title — stems like "Find" are too thin for care-plan sentences.
        if let best = candidates.max(by: { $0.count < $1.count }) {
            return best
        }
        return "Untitled detail"
    }

    /// Reduce a free-text title to a stable stem so related cards stack.
    static func clusterStem(from raw: String, category: SummaryEntryCategory) -> String {
        var s = stripMarkers(raw)
        guard !s.isEmpty else { return "" }

        // Cut trailing detail if separators survived into the title.
        for sep in [" — ", " – ", " - ", ": "] {
            if let range = s.range(of: sep) {
                let head = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if head.count >= 3 { s = head; break }
            }
        }
        if let paren = s.range(of: " (") {
            let head = String(s[..<paren.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if head.count >= 3 { s = head }
        }
        // First comma clause when the head is still a short label.
        if let comma = s.range(of: ", ") {
            let head = String(s[..<comma.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (3...40).contains(head.count) { s = head }
        }

        s = stripWrappers(s)

        if category == .medications {
            s = stripMedicationNoise(s)
        }

        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        s = aliasCanonical(s)
        s = significantStem(from: s)
        return aliasCanonical(s)
    }

    static func sortNewestFirst(_ lhs: SummaryEntry, _ rhs: SummaryEntry) -> Bool {
        if lhs.origin == .userAdded, rhs.origin != .userAdded { return false }
        if lhs.origin != .userAdded, rhs.origin == .userAdded { return true }
        if lhs.origin == .userAdded, rhs.origin == .userAdded {
            return lhs.createdAt < rhs.createdAt
        }
        return occurrenceDate(lhs) > occurrenceDate(rhs)
    }

    static func occurrenceDate(_ entry: SummaryEntry) -> Date {
        entry.relevantDate ?? entry.sourceDate ?? entry.createdAt
    }

    // MARK: - Normalization helpers

    private static func stripMarkers(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("- ") || s.hasPrefix("• ") || s.hasPrefix("* ") {
            s = String(s.dropFirst(2))
        } else if let range = s.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        s = s.lowercased()
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        while let last = s.last, ".,:;!?".contains(last) {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let wrappers = [
        "ongoing ",
        "history of ",
        "reports of ",
        "report of ",
        "complains of ",
        "complaint of ",
        "presents with ",
        "presenting with ",
        "noted ",
        "chronic ",
        "recurrent ",
        "intermittent ",
        "severe ",
        "mild ",
        "moderate ",
        "worsening ",
        "improving ",
        "new ",
        "possible ",
        "probable ",
        "suspected ",
    ]

    private static func stripWrappers(_ raw: String) -> String {
        var s = raw
        var changed = true
        while changed {
            changed = false
            for prefix in wrappers where s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                changed = true
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripMedicationNoise(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(
            of: #"\b\d+([.,]\d+)?\s*(mg|mcg|µg|ug|g|ml|%|iu|units?)\b"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\b(once|twice|three times|qid|tid|bid|qd|prn|daily|nightly|hourly)\b"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "with", "and", "or", "to", "for", "in", "on", "at",
        "due", "from", "into", "over", "under", "without", "within", "vs", "via",
    ]

    private static let keptBigrams: Set<String> = [
        "back pain", "low back", "chest pain", "joint pain", "abdominal pain",
        "blood pressure", "care plan", "follow up", "mental health", "side effect",
        "side effects", "home exercise", "physical therapy",
    ]

    /// Keep a short entity stem for labels like "migraine", but preserve longer care-plan / instruction sentences.
    private static func significantStem(from raw: String) -> String {
        let words = raw
            .split(whereSeparator: { $0.isWhitespace || "-/".contains($0) })
            .map(String.init)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
        guard !words.isEmpty else { return raw }

        // Instructional / multi-word lines: keep a longer fingerprint so "Find a neutral…"
        // does not collapse to the verb "find" (and wrongly merge unrelated "Find …" items).
        if words.count >= 4 {
            return Array(words.prefix(8)).joined(separator: " ")
        }

        if words.count >= 2 {
            let bi = "\(words[0]) \(words[1])"
            if keptBigrams.contains(bi) || aliasMap[bi] != nil {
                return bi
            }
            if words.count >= 3, words[0] == "low", words[1] == "back" {
                return "low back pain"
            }
        }
        // Long first token is usually the clinical entity (migraine, metformin, hypertension).
        // Require 5+ chars so short verbs like "find" / "take" do not become the whole key.
        if let first = words.first, first.count >= 5 {
            return first
        }
        return Array(words.prefix(min(3, words.count))).joined(separator: " ")
    }

    /// Maps aliases onto a single canonical token. Keep conservative.
    private static let aliasMap: [String: String] = [
        "migraines": "migraine",
        "migraine headache": "migraine",
        "migraine headaches": "migraine",
        "headaches": "headache",
        "low back pain": "low back pain",
        "lower back pain": "low back pain",
        "lbp": "low back pain",
        "shortness of breath": "shortness of breath",
        "sob": "shortness of breath",
        "dyspnea": "shortness of breath",
        "nauseas": "nausea",
        "nauseous": "nausea",
        "follow ups": "follow up",
        "follow-up": "follow up",
        "followups": "follow up",
        "htn": "hypertension",
        "high blood pressure": "hypertension",
        "blood pressure": "hypertension",
        "dm": "diabetes",
        "diabetes mellitus": "diabetes",
        "type 2 diabetes": "diabetes",
        "type ii diabetes": "diabetes",
    ]

    private static func aliasCanonical(_ raw: String) -> String {
        aliasMap[raw] ?? raw
    }
}

// MARK: - Clusters

struct SummaryEntryCluster: Identifiable {
    let id: String
    let canonicalTitle: String
    let entries: [SummaryEntry]
    let aggregateBullets: [String]
    let overflowCount: Int

    var isStack: Bool { entries.count > 1 }

    var dateRangeText: String? {
        let dates = entries.map { SummaryEntryClusterKey.occurrenceDate($0) }.sorted()
        guard let oldest = dates.first, let newest = dates.last else { return nil }
        let fmt = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if Calendar.current.isDate(oldest, inSameDayAs: newest) {
            return oldest.formatted(fmt)
        }
        return "\(oldest.formatted(fmt)) – \(newest.formatted(fmt))"
    }

    /// Current if any source is current; otherwise past.
    var clinicalStatus: SummaryEntryClinicalStatus {
        SummaryEntryClinicalStatus.dominant(in: entries.map(\.clinicalStatus))
    }

    /// Newest source date in the stack — used for recency sorting within a status section.
    var newestOccurrenceDate: Date {
        entries.map(SummaryEntryClusterKey.occurrenceDate).max() ?? .distantPast
    }

    /// Entries ordered newest-first for expanded source lists.
    var entriesNewestFirst: [SummaryEntry] {
        entries.sorted(by: SummaryEntryClusterKey.sortNewestFirst)
    }

    /// One-line sentence for the collapsed row — prefer the fullest entry wording, not the cluster stem.
    var sentenceSummary: String {
        let ordered = entries.sorted(by: SummaryEntryClusterKey.sortNewestFirst)
        let sentences = ordered.map {
            SummaryEntrySentence.make(title: $0.title, details: $0.details)
        }
        .filter { !$0.isEmpty }

        // Prefer the longest descriptive sentence among sources (avoids "Find" when the
        // full line is "Find a neutral position of the pelvis while sitting").
        if let best = sentences.max(by: { $0.count < $1.count }) {
            return best
        }
        return canonicalTitle
    }
}

/// Combine title + details into a single tight sentence for list rows.
enum SummaryEntrySentence {
    static func make(title: String, details: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            return d.isEmpty ? "Untitled detail" : d
        }
        if d.isEmpty { return t }
        if d.caseInsensitiveCompare(t) == .orderedSame { return t }
        if d.localizedCaseInsensitiveContains(t) { return d }
        for sep in [" — ", " – ", " - ", ": "] {
            if d.hasPrefix(t + sep) {
                return d
            }
            if t.hasPrefix(d) { return t }
        }
        // Short entity + elaboration → one line.
        if t.count <= 48 {
            return "\(t) — \(d)"
        }
        return d
    }
}

/// Groups and sorts clusters for summary lists: status (current → past), then recency.
enum SummaryEntryClusterOrdering {
    static func statusSections(from clusters: [SummaryEntryCluster]) -> [(status: SummaryEntryClinicalStatus, clusters: [SummaryEntryCluster])] {
        SummaryEntryClinicalStatus.summarySectionOrder.compactMap { status in
            let matches = clusters
                .filter { $0.clinicalStatus == status }
                .sorted { $0.newestOccurrenceDate > $1.newestOccurrenceDate }
            guard !matches.isEmpty else { return nil }
            return (status, matches)
        }
    }
}

enum SummaryEntryClusterBuilder {
    static let aggregateBulletCap = 5

    /// Groups entries for display by stem title (all categories), then merges containment overlaps.
    static func clusters(from entries: [SummaryEntry], category: SummaryEntryCategory) -> [SummaryEntryCluster] {
        var buckets: [String: [SummaryEntry]] = [:]
        var order: [String] = []
        var singles: [SummaryEntry] = []

        for entry in entries {
            guard let key = SummaryEntryClusterKey.key(for: entry) else {
                singles.append(entry)
                continue
            }
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key, default: []].append(entry)
        }

        mergeContainedKeys(order: &order, buckets: &buckets)

        var result: [SummaryEntryCluster] = []
        for key in order {
            guard var group = buckets[key], !group.isEmpty else { continue }
            group.sort(by: SummaryEntryClusterKey.sortNewestFirst)
            result.append(makeCluster(id: key, entries: group))
        }
        for entry in singles {
            result.append(singleCluster(from: [entry]))
        }

        return result.sorted { lhs, rhs in
            let l = lhs.entries.first.map(SummaryEntryClusterKey.occurrenceDate) ?? .distantPast
            let r = rhs.entries.first.map(SummaryEntryClusterKey.occurrenceDate) ?? .distantPast
            return l > r
        }
    }

    /// Merge "migraine" into the same bucket as keys that are clearly the same stem.
    private static func mergeContainedKeys(order: inout [String], buckets: inout [String: [SummaryEntry]]) {
        guard order.count > 1 else { return }

        func stemPart(_ key: String) -> String {
            String(key.split(separator: "|").last ?? Substring(key))
        }

        var i = 0
        while i < order.count {
            let keyA = order[i]
            let stemA = stemPart(keyA)
            guard stemA.count >= 4 else {
                i += 1
                continue
            }
            var j = i + 1
            while j < order.count {
                let keyB = order[j]
                // Only merge within the same category (+ body system) prefix.
                let prefixA = keyA.split(separator: "|").dropLast().joined(separator: "|")
                let prefixB = keyB.split(separator: "|").dropLast().joined(separator: "|")
                guard prefixA == prefixB else {
                    j += 1
                    continue
                }
                let stemB = stemPart(keyB)
                let related = stemA == stemB
                    || (stemA.count >= 4 && stemB.hasPrefix(stemA))
                    || (stemB.count >= 4 && stemA.hasPrefix(stemB))
                guard related else {
                    j += 1
                    continue
                }
                // Keep the shorter stem as the surviving key.
                let keep = stemA.count <= stemB.count ? keyA : keyB
                let drop = keep == keyA ? keyB : keyA
                buckets[keep, default: []].append(contentsOf: buckets[drop] ?? [])
                buckets[drop] = nil
                order.removeAll { $0 == drop }
                if drop == keyA {
                    // Restart outer loop index for the kept key's new position.
                    i = order.firstIndex(of: keep) ?? i
                    break
                }
                // dropped keyB; do not advance j
            }
            i += 1
        }
    }

    private static func singleCluster(from entries: [SummaryEntry]) -> SummaryEntryCluster {
        let id = entries.first?.id.uuidString ?? UUID().uuidString
        return makeCluster(id: id, entries: entries)
    }

    private static func makeCluster(id: String, entries: [SummaryEntry]) -> SummaryEntryCluster {
        let title = SummaryEntryClusterKey.displayTitle(for: entries)
        let (bullets, overflow) = SummaryEntryStackAggregator.aggregateBullets(
            from: entries,
            canonicalTitle: title,
            cap: aggregateBulletCap
        )
        return SummaryEntryCluster(
            id: id,
            canonicalTitle: title,
            entries: entries,
            aggregateBullets: bullets,
            overflowCount: overflow
        )
    }
}

// MARK: - Aggregate summary

enum SummaryEntryStackAggregator {
    /// Extractive dedupe of details/fields across occurrences (newest first). No invented clinical text.
    static func aggregateBullets(
        from entries: [SummaryEntry],
        canonicalTitle: String,
        cap: Int
    ) -> (bullets: [String], overflow: Int) {
        let ordered = entries.sorted(by: SummaryEntryClusterKey.sortNewestFirst)
        var seen = Set<String>()
        var collected: [String] = []

        for entry in ordered {
            for line in candidateLines(from: entry, canonicalTitle: canonicalTitle) {
                let norm = normalizeForDedupe(line)
                guard !norm.isEmpty else { continue }
                if norm == normalizeForDedupe(canonicalTitle) { continue }
                // Skip lines that are only the stem repeated.
                if SummaryEntryClusterKey.clusterStem(from: line, category: entry.category)
                    == SummaryEntryClusterKey.clusterStem(from: canonicalTitle, category: entry.category) {
                    // Allow if the line is longer and adds content beyond the stem.
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count <= canonicalTitle.count + 2 { continue }
                }
                if seen.contains(norm) { continue }
                seen.insert(norm)
                collected.append(line)
            }
        }

        if collected.isEmpty {
            // Pull leftover title detail when the model left everything in the title.
            for entry in ordered {
                let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let stem = SummaryEntryClusterKey.clusterStem(from: title, category: entry.category)
                if title.count > stem.count + 3 {
                    let remainder = title
                    let norm = normalizeForDedupe(remainder)
                    if !norm.isEmpty, !seen.contains(norm), norm != normalizeForDedupe(canonicalTitle) {
                        seen.insert(norm)
                        collected.append(remainder)
                    }
                }
            }
        }

        if collected.isEmpty {
            let n = entries.count
            let fallback = n > 1
                ? "Noted across \(n) sources"
                : "Tap to view source details"
            return ([fallback], 0)
        }

        if collected.count <= cap {
            return (collected, 0)
        }
        return (Array(collected.prefix(cap)), collected.count - cap)
    }

    private static func candidateLines(from entry: SummaryEntry, canonicalTitle: String) -> [String] {
        var lines: [String] = []

        if let details = uniqueDetails(from: entry, displayTitle: entryTitle(entry)) {
            lines.append(contentsOf: splitIntoLines(details))
        }

        // If title is longer than the stem, treat the non-stem remainder as a detail line.
        let title = entryTitle(entry)
        let stem = SummaryEntryClusterKey.clusterStem(from: title, category: entry.category)
        if !stem.isEmpty, title.lowercased().hasPrefix(stem), title.count > stem.count + 2 {
            let rest = String(title.dropFirst(stem.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " -—,.:"))
            if rest.count > 2 {
                lines.append(rest)
            }
        }

        let titleNorm = normalizeForDedupe(title)
        let canonicalNorm = normalizeForDedupe(canonicalTitle)
        let detailsNorm = normalizeForDedupe(entry.details)

        for field in entry.fields {
            if isPractitionerOrSessionField(field) { continue }
            if field.label.caseInsensitiveCompare(BodySystem.fieldLabel) == .orderedSame { continue }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !field.isMissing else { continue }
            let valueNorm = normalizeForDedupe(value)
            if valueNorm == titleNorm || valueNorm == canonicalNorm { continue }
            if !detailsNorm.isEmpty, valueNorm == detailsNorm { continue }
            lines.append(value)
        }

        return lines
    }

    private static func entryTitle(_ entry: SummaryEntry) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled detail" : trimmed
    }

    /// Same echo rules as AtomicSummaryEntryCard.uniqueDetailsText.
    static func uniqueDetails(from entry: SummaryEntry, displayTitle: String) -> String? {
        let details = entry.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !details.isEmpty else { return nil }
        if details.caseInsensitiveCompare(displayTitle) == .orderedSame { return nil }
        for sep in [" — ", " – ", " - "] {
            if details.hasPrefix(displayTitle + sep) {
                let rest = String(details.dropFirst(displayTitle.count + sep.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty || rest.caseInsensitiveCompare(displayTitle) == .orderedSame {
                    return nil
                }
            }
        }
        return details
    }

    private static func splitIntoLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeForDedupe(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func isPractitionerOrSessionField(_ field: SummaryEntryField) -> Bool {
        let label = field.label.lowercased()
        return label.contains("practitioner")
            || label.contains("provider")
            || label.contains("clinician")
            || label.contains("session")
    }
}
