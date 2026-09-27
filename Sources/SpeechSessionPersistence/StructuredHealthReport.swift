import Foundation

/// Source-aware segmentation, not clinical interpretation or automatic admission.
public enum StructuredHealthReport {
    public enum Kind: String, Sendable { case lab, medication, immunization, general }
    public struct Unit: Sendable {
        public let kind: Kind
        public let source: String
        public let heading: String
    }
    private static func isOrderHeader(_ line: String) -> Bool {
        line.range(of: #"(?i)\b(ordered by|ordering provider)\b"#, options: .regularExpression) != nil
    }
    public static func recognizes(_ source: String) -> Bool {
        let text = source.lowercased()
        return (text.contains("test name") && text.contains("result") && (text.contains("ordered by") || text.contains("ordering provider")))
            || ((text.contains("immunizations") || text.contains("vaccinations")) && text.contains("date administered"))
            || (text.contains("medication name") && (text.contains("date filled") || text.contains("date started")))
    }
    public static func units(in source: String) -> [Unit]? {
        guard recognizes(source) else { return nil }
        let lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var section = "", originalHeading = "", order: [String] = [], lab: [String] = [], rows: [Unit] = [], tableHeader = ""
        var skipFooterContinuation = false
        var remainder: [String] = []
        func flushLab() {
            if !lab.isEmpty { rows.append(Unit(kind: .lab, source: ([originalHeading] + order + lab).joined(separator: "\n"), heading: "Lab Results")); lab = [] }
        }
        for line in lines {
            if line.lowercased().contains("your health information is private") { skipFooterContinuation = true; continue }
            if skipFooterContinuation {
                if line == "with people you trust." { skipFooterContinuation = false; continue }
                skipFooterContinuation = false
            }
            if line.isEmpty || line.lowercased().contains("is a service provided by") || line.range(of: #"^-{2,3} Page \d+ ---$|\|.*Page:\s*\d+$"#, options: .regularExpression) != nil { continue }
            let headings = ["lab results": "Lab Results", "laboratory results": "Lab Results", "immunizations": "Immunizations", "vaccinations": "Immunizations", "medications (active)": "Medications (Active)", "active medications": "Medications (Active)", "medications (discontinued)": "Medications (Discontinued)", "discontinued medications": "Medications (Discontinued)", "medications (fills)": "Medications (Fills)", "prescription fills": "Medications (Fills)", "demographic information": "Demographic Information", "table of contents": "Table of Contents"]
            if let heading = headings[line.lowercased()] {
                flushLab(); section = heading; originalHeading = line; order = []; tableHeader = ""; continue
            }
            if section == "Lab Results" {
                if isOrderHeader(line) {
                    flushLab(); order = [line]; continue
                }
                if order.count == 1 { order.append(line); continue }
                if ["test name", "test name result", "analyte", "analyte result"].contains(line.lowercased()) {
                    flushLab(); lab = [line]; continue
                }
                if lab.isEmpty { order.append(line) } else { lab.append(line) }
            } else if section.hasPrefix("Medications (") || section == "Immunizations" {
                if line.lowercased().hasPrefix("medication name ") || line.lowercased().hasPrefix("date administered ") { tableHeader = line; continue }
                // Preserve each complete table row with its own headings. Carry headings across pages.
                rows.append(Unit(kind: section == "Immunizations" ? .immunization : .medication,
                    source: [originalHeading, tableHeader, line].filter { !$0.isEmpty }.joined(separator: "\n"), heading: section))
            } else if !["Demographic Information", "Table of Contents"].contains(section) {
                remainder.append(line)
            }
        }
        flushLab()
        guard !rows.isEmpty else { return nil }
        for fragment in SourceTextChunks.split(remainder.joined(separator: "\n"), limit: 1500) {
            rows.append(Unit(kind: .general, source: fragment, heading: "Other source content"))
        }
        return rows
    }

    /// Batch adjacent compatible units without cutting a row away from its inherited context.
    public static func batches(_ units: [Unit], limit: Int) -> [Unit] {
        var result: [Unit] = []
        var count = 0
        for unit in units {
            if let previous = result.last, previous.kind == unit.kind, previous.heading == unit.heading,
               count < 3, previous.source.count + unit.source.count + 2 <= limit {
                result[result.count - 1] = Unit(kind: unit.kind, source: previous.source + "\n\n" + unit.source, heading: unit.heading)
                count += 1
            } else { result.append(unit); count = 1 }
        }
        return result
    }

    /// Copy complete, explicitly labelled lab rows without asking a model to select
    /// which values matter. Ambiguous layouts fall back to the existing extractor.
    /// These are drafts: normal source checking still runs before publication.
    public static func labDrafts(in unit: Unit, session: Session) -> [SummaryEntry]? {
        guard unit.kind == .lab, let rows = units(in: unit.source),
              !rows.isEmpty, rows.allSatisfy({ $0.kind == .lab }) else { return nil }
        var drafts: [SummaryEntry] = []
        let labels = Set(["Test Name", "Result", "Reference Range (Units)", "Abnormality", "Result Comment"])
        for row in rows {
            let lines = row.source.components(separatedBy: .newlines)
            func value(_ label: String) -> String? {
                let indices = lines.indices.filter { lines[$0] == label }
                guard indices.count == 1, let i = indices.first, i + 1 < lines.count,
                      !lines[i + 1].isEmpty, !labels.contains(lines[i + 1]) else { return nil }
                return lines[i + 1]
            }
            guard let name = value("Test Name"), let result = value("Result"),
                  result.range(of: #"^[<>≤≥=]?\s*\d+(?:\.\d+)?\s+\S+"#, options: .regularExpression) != nil,
                  let range = value("Reference Range (Units)"),
                  (range == "-" || range.range(of: #"^[<>≤≥=\d]"#, options: .regularExpression) != nil),
                  let flag = value("Abnormality"),
                  ["-", "Above normal range", "Below normal range"].contains(flag) else { return nil }
            var fields = [SummaryEntryField(label: "Result", value: result)]
            if range != "-" { fields.append(.init(label: "Reference range", value: range)) }
            if flag != "-" { fields.append(.init(label: "Abnormality", value: flag)) }
            var entry = SummaryEntry(category: .testsAndLabs, title: name, fields: fields,
                sourceSessionID: session.id, sourceTitle: session.title, sourceDate: session.date,
                sourceExcerpt: row.source, needsReview: true)
            entry.evidence = ClinicalEvidence()
            entry.evidence?.excerpt = row.source
            if let header = lines.first(where: { isOrderHeader($0) }),
               let boundary = header.range(of: #"(?i)\s+(ordered by|ordering provider)\b"#, options: .regularExpression) {
                let date = String(header[..<boundary.lowerBound])
                if date.range(of: #"^[A-Za-z]{3} \d{1,2}, \d{4}"#, options: .regularExpression) != nil {
                    entry.evidence?.eventDate = date
                }
            }
            drafts.append(entry)
        }
        return drafts
    }

    /// Organization labels generated by the app are not clinical assertions from a lab report.
    public static func prepare(_ entry: SummaryEntry, for unit: Unit) -> SummaryEntry {
        var entry = entry
        guard unit.kind != .general else { return entry }
        if unit.kind == .lab && entry.category == .findings { entry.category = .testsAndLabs }
        if unit.kind == .immunization && [.medications, .findings, .testsAndLabs].contains(entry.category) {
            entry.category = .vaccinations
        }
        entry.evidence?.bodySystem = nil
        entry.evidence?.topicNames = nil
        entry.fields.removeAll { ["body area", "body system", "topic", "topics", "clinical status"].contains($0.label.lowercased()) }
        if unit.kind != .medication {
            entry.evidence?.statusExplicit = false
            entry.clinicalStatus = .current // Default patient control, not the source's “Final” report status.
        }
        return entry
    }

    public static func orderingContacts(in source: String, session: Session) -> [SummaryEntry] {
        guard recognizes(source) else { return [] }
        let lines = source.components(separatedBy: .newlines)
        var seen = Set<String>(), entries: [SummaryEntry] = []
        for index in lines.indices where isOrderHeader(lines[index]) && index + 1 < lines.count {
            let name = lines[index + 1].trimmingCharacters(in: .whitespaces)
            guard name.range(of: #"^[\p{L}'’-]+(?:[ ,]+[\p{L}'’-]+)+$"#, options: .regularExpression) != nil,
                  seen.insert(name).inserted else { continue }
            let excerpt = lines[index] + "\n" + lines[index + 1]
            entries.append(SummaryEntry(category: .practitionerContact, title: name,
                fields: [.init(label: "Name", value: name), .init(label: "Role or specialty", value: "Ordering clinician")],
                sourceSessionID: session.id, sourceTitle: session.title, sourceDate: session.date,
                sourceExcerpt: excerpt, provenance: "Ordered By", needsReview: true))
        }
        return entries
    }
}
