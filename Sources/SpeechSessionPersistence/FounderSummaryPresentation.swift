import Foundation

/// Read-only organization for the founder V1 handoff. Original statements and
/// citations are retained; this layer never invents a diagnosis, date or status.
public struct FounderSummaryPresentation {
    public let blocks: [StorySummaryBlock]
    public let dates: [StorySummaryBulletDate]
    public let sources: [String: [String]]

    public init(summary: StorySharedSummary, hasAbnormalLabs: Bool, patientName: String?) {
        let original = StorySummaryDocument.practitionerPresentation(summary.text, hasAbnormalLabs: hasAbnormalLabs, bulletDates: summary.bulletDates ?? [], providerContacts: summary.providerContacts ?? [], patientName: patientName)
        // Preserve legacy prose/tables wholesale until regenerated into the structured
        // contract. A presentation upgrade must never silently discard saved content.
        if original.blocks.contains(where: { block in
            switch block { case .paragraph, .table: return true; default: return false }
        }) {
            blocks = original.blocks; dates = original.dates; sources = [:]
            return
        }
        struct Row {
            var text: String
            var group: String
            var date: String
            var sortDate: String?
            var status: String
            var citations: [String]
        }
        var sections: [String: [Row]] = [:]
        var section = ""
        let allowed = Set(summary.evidence.map(\.id))
        for block in original.blocks {
            if case let .heading(title, level) = block, level == 2 { section = title; continue }
            guard section != "Appointment Preparation Brief", case let .bullet(text) = block else { continue }
            let parts = Set(StorySummaryDocument.splitShareItems(.bullet(text)).compactMap { if case let .bullet(value) = $0 { return value }; return nil })
            let refs = (summary.pointReferences ?? []).filter { ref in
                guard ref.heading == section else { return false }
                return StorySummaryDocument.splitShareItems(.bullet(StorySummaryDocument.shareShorthand(ref.text))).contains { block in
                    guard case let .bullet(value) = block else { return false }
                    if parts.contains(value) { return true }
                    // Provider enrichment adds contact fields to an otherwise unchanged note.
                    let note = StorySummaryDocument.topicAndNote(value).note
                    return section == "Care Coordination Summary" && note.count > 8 && text.contains(note)
                }
            }
            let fields = StorySummaryDocument.topicAndNote(text)
            let groups = Set(refs.compactMap(\.conditionGroup).filter { !$0.isEmpty })
            let group = groups.count == 1 ? groups.first! : (fields.topic.isEmpty ? "Other recorded history" : fields.topic)
            let metadata = original.dates.first { $0.text == text }
            let period = refs.compactMap(\.timeLabel).first
            let when = Self.when(text: text, metadata: metadata, period: period)
            let statuses = Set(refs.compactMap(\.careStatus))
            let displayedText: String
            if section == "Care Coordination Summary" {
                let anonymous = ["referring colleague", "headache clinician", "antenatal follow-up", "previous midwife", "home-birth midwives", "home birth midwives"]
                if anonymous.contains(fields.topic.lowercased()) { continue }
                if fields.note.range(of:#"(?i)\b(?:recommended|suggested|proposed|considering|not booked|never seen)\b"#,options:.regularExpression) != nil,
                   fields.note.range(of:#"(?i)\b(?:treated|consulted|attended|received care|previously saw)\b"#,options:.regularExpression) == nil { continue }
                displayedText = Self.cleanProviderText(text)
            } else { displayedText = text }
            let row = Row(text: displayedText, group: group, date: when.label, sortDate: when.sort, status: statuses.count == 1 ? statuses.first! : "—", citations: Array(Set(refs.flatMap(\.citationIDs).filter { allowed.contains($0) })).sorted())
            sections[section, default: []].append(row)
        }
        var result: [StorySummaryBlock] = []
        var sourceMap: [String: [String]] = [:]
        var displayDates: [StorySummaryBulletDate] = []
        func remember(_ row: Row) {
            sourceMap[row.text] = Array(Set((sourceMap[row.text] ?? []) + row.citations)).sorted()
            var date = StorySummaryBulletDate(text:row.text,labels:[])
            date.displayOverride = row.date
            displayDates.append(date)
        }
        func unique(_ rows: [Row]) -> [Row] {
            var output: [Row] = [], indices: [String: Int] = [:]
            for row in rows {
                let key = row.text.lowercased() + "|" + row.date
                if let index = indices[key] { output[index].citations = Array(Set(output[index].citations + row.citations)).sorted() }
                else { indices[key] = output.count; output.append(row) }
            }
            return output
        }
        var groupOrder: [String: Int] = [:]
        for section in ["Clinical Snapshot","Comprehensive Health History","Condition-Specific Summary","Care Plan & Interventions"] {
            for row in sections[section] ?? [] where groupOrder[row.group.lowercased()] == nil { groupOrder[row.group.lowercased()] = groupOrder.count }
        }
        func groups(_ rows: [Row]) -> [(String, [Row])] {
            var output: [(String, [Row])] = [], indices: [String: Int] = [:]
            for row in rows {
                let key = row.group.lowercased()
                if let index = indices[key] { output[index].1.append(row) }
                else { indices[key] = output.count; output.append((row.group, [row])) }
            }
            return output.sorted { (groupOrder[$0.0.lowercased()] ?? Int.max) < (groupOrder[$1.0.lowercased()] ?? Int.max) }
        }
        let snapshot = unique(sections["Clinical Snapshot"] ?? [])
        if !snapshot.isEmpty {
            result.append(.heading("Clinical Snapshot", level: 2))
            for (group, rows) in groups(snapshot) {
                result.append(.heading(group, level: 3))
                for row in rows {
                    var shown = row
                    let fields = StorySummaryDocument.topicAndNote(row.text)
                    if fields.topic.caseInsensitiveCompare(group) == .orderedSame { shown.text = fields.note }
                    result.append(.bullet(shown.text)); remember(shown)
                }
            }
        }
        var providers: [Row] = []
        var providerIndices: [String: Int] = [:]
        for row in unique(sections["Care Coordination Summary"] ?? []) {
            let fields = StorySummaryDocument.topicAndNote(row.text)
            let name = fields.topic.components(separatedBy:",").first!.lowercased().replacingOccurrences(of:#"^(?:dr\.?|mr\.?|ms\.?|mrs\.?)\s+"#,with:"",options:.regularExpression).trimmingCharacters(in:.whitespaces)
            if let index = providerIndices[name] {
                let previous = StorySummaryDocument.topicAndNote(providers[index].text)
                let title = previous.topic.count >= fields.topic.count ? previous.topic : fields.topic
                let notes = previous.note == fields.note ? [previous.note] : [previous.note, fields.note]
                providers[index].text = title + " — " + notes.joined(separator:"; ")
                providers[index].citations = Array(Set(providers[index].citations + row.citations)).sorted()
                if providers[index].date != row.date { providers[index].date = [providers[index].date,row.date].filter{$0 != "History"}.joined(separator:"; ") }
            } else { providerIndices[name] = providers.count; providers.append(row) }
        }
        if !providers.isEmpty {
            result.append(.heading("Care Coordination Summary", level: 2))
            let rows = providers.map { row -> [String] in
                remember(row)
                let fields = StorySummaryDocument.topicAndNote(row.text)
                return [fields.topic, fields.note, row.date == "History" ? "—" : row.date]
            }
            result.append(.table(headers: ["Practitioner", "Practice, contact & care", "When"], rows: rows))
        }
        let history = unique((sections["Comprehensive Health History"] ?? []) + (sections["Condition-Specific Summary"] ?? []))
        if !history.isEmpty {
            result.append(.heading("Condition-Specific Summary", level: 2))
            for (index, entry) in groups(history).enumerated() {
                result.append(.heading("\(index + 1). \(entry.0)", level: 3))
                let ordered = entry.1.enumerated().sorted { a, b in
                    if a.element.sortDate != b.element.sortDate { return (a.element.sortDate ?? "") < (b.element.sortDate ?? "") }
                    return a.offset < b.offset
                }.map(\.element)
                result.append(.table(headers: ["When", "Detail"], rows: ordered.map { row in remember(row); return [row.date, row.text] }))
            }
        }
        let care = unique(sections["Care Plan & Interventions"] ?? [])
        if !care.isEmpty {
            result.append(.heading("Care Plan & Interventions", level: 2))
            // Preserve supplied group order; source-backed current pregnancy groups first.
            let grouped = groups(care).enumerated().sorted { a,b in
                func pregnancy(_ value: String) -> Bool { value.localizedCaseInsensitiveContains("pregnancy") && !value.localizedCaseInsensitiveContains("prior") && !value.localizedCaseInsensitiveContains("previous") }
                if pregnancy(a.element.0) != pregnancy(b.element.0) { return pregnancy(a.element.0) }
                return a.offset < b.offset
            }.map(\.element)
            for (group, rows) in grouped {
                result.append(.heading(group, level: 3))
                result.append(.table(headers: ["Item", "Detail", "Status", "Date"], rows: rows.map { row in
                    remember(row); let fields = StorySummaryDocument.topicAndNote(row.text)
                    return [fields.topic, fields.note, row.status, row.date == "History" ? "—" : row.date]
                }))
            }
        }
        let labs = unique(sections["Labs & Investigations"] ?? [])
        if hasAbnormalLabs || !labs.isEmpty {
            result.append(.heading("Labs & Investigations", level: 2))
            for row in labs { result.append(.bullet(row.text)); remember(row) }
        }
        blocks = result; dates = displayDates; sources = sourceMap
    }

    private static func cleanProviderText(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(?:[;,]\s*)?\b(?:licen[cs]e|registration|reg\.)(?:\s*(?:number|no\.?|#))?\s*[:#]?\s*[A-Z]*[- ]?\d[\w-]*"#, with: "", options:.regularExpression)
            .replacingOccurrences(of:#"(?i)(?:;\s*)?(?:now a colleague|declined because of (?:the )?colleague relationship|\w+ practice since \d{4}[^;]*|at (?:this |the )?location [^;]*)"#,with:"",options:.regularExpression)
            .trimmingCharacters(in:.whitespacesAndNewlines)
    }

    public static func when(text: String, metadata: StorySummaryBulletDate?, period: String?) -> (label: String, sort: String?) {
        let relative = #"(?i)\b(?:\d+|ten|five|six)\s*(?:[–-]\s*\d+\s*)?years?\s+(?:before|after|ago|prior to)\b"#
        let hasRelative = text.range(of: relative, options: .regularExpression) != nil
        if !hasRelative, let temporal = metadata?.temporal, ["event", "ongoing"].contains(temporal.role), let start = temporal.start {
            let label = metadata?.displayLabel() ?? start
            return (label, start)
        }
        if let period, !period.isEmpty { return (period, nil) }
        for stage in ["Before prior pregnancy", "Prior pregnancy", "Previous pregnancy", "Prior postpartum", "Childhood", "First pregnancy"] where text.localizedCaseInsensitiveContains(stage) { return (stage, nil) }
        if !hasRelative, metadata?.temporal == nil, let year = StorySummaryBulletDate.historyDisplayDate(text:text,labels:[]) { return (year,year) }
        // A label inferred from a note or upload is never an event date.
        return ("History", nil)
    }
}
