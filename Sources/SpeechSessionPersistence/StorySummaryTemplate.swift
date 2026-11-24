import Foundation

/// Presentation templates never change the underlying health record.
public enum StorySummaryTemplate:String,CaseIterable,Codable,Sendable {
    case practitioner = "practitioner-v1"
    public var title:String {"Practitioner summary"}
    public var sections:[String] {[
        "Clinical Snapshot", "Care Coordination Summary", "Appointment Preparation Brief",
        "Comprehensive Health History", "Condition-Specific Summary", "Care Plan & Interventions", "Labs & Investigations"
    ]}
    public var prompt:String {
        """
        Produce a single shareable practitioner summary from the supplied saved health facts. This is a formatting template, not a request for medical advice. Return kind=answer and the whole document in text, with no introduction or chat commentary.
        If evidence explicitly identifies the patient by name, start with one line "Patient name: <name>". Otherwise omit that line. Never infer the patient name from the account, a clinician name, or a document title alone.
        Use these exact headings in this order, each on its own line prefixed with ##:
        \(sections.joined(separator:"\n"))
        Write a selective clinical handoff in chart shorthand, not an inventory of every saved fact. Maximum 18 words per bullet. No fixed total-word or page target. Retain all distinct clinically relevant context, concerns, medications, decisions, unresolved questions and next steps. Let relevant content determine length; remove repetition and procedural explanation rather than useful clinical points. Target 6–12 words per bullet. Consolidate related concerns and repeated history across sections. Select material concerns, current medication names/status, allergies, meaningful changes, decisions, questions and agreed follow-up. Omit procedural teaching, incidental anecdotes and missing-information commentary. Never weaken declined to deferred or remove meaningful uncertainty to save words. Rewrite rather than truncate. Every bullet has the form "- Topic — qualifier". Topic is a clinical noun phrase (1–6 words); qualifier is a short fragment (1–12 words). Usually 4–9 words total. Use active verbs or concise noun phrases. Avoid repeated wording and aim for one short line per bullet. Use w/ instead of with. Remove filler such as "that", "the patient", "according to the record" and "it was reported". Do not narrate where facts came from or repeatedly say information is not confirmed. Preserve a meaningful qualifier in a word or two (possible, suspected, declined, considering, per parent) when it changes the clinical meaning. Do not turn an uncertain diagnosis into a confirmed one or a suggestion into an agreed plan. No complete sentences, reporting lead-ins, semicolons or final periods. Keep one topic per line. Use separate bullets for each semicolon-separated item in the input. Repeat its topic, person, or condition where needed so each bullet stands on its own. Use separate bullets for unrelated decisions. No padding to fill a page.
        Style examples only (never add their facts): "- Ankle pain — intermittent, worse on stairs"; "- Brace — declined today, possible retrial next visit"; "- Follow-up — booked for Friday at 10 am". Preserve meaningful attribution with compact qualifiers such as "per parent" or "suspected". Omit boilerplate such as “patient reports” and “not documented”. Preserve uncertainty, timing and who proposed or agreed to an action when clinically meaningful. Use established, unambiguous clinical abbreviations across all sections (e.g. LDL); never invent an acronym. Give each distinct perspective an appropriate home. Write each section as concise bullet points. Start each point on its own line with '- '. Use one material finding or action per bullet and keep its qualifiers together.
        SECTION PURPOSE AND COVERAGE: Clinical Snapshot gives the current clinical context, main concerns, functional impact, relevant personal circumstances and expressed patient priorities or practical constraints. Care Coordination Summary includes relevant named current, referred, proposed and previous care providers and services, with their supported roles, relationships and responsibilities. Include providers without a new agreed action; distinguish proposed or former care from active care. Do not invent responsibility or omit a provider because treatment appears elsewhere. Appointment Preparation Brief captures the recorded visit purpose, open questions and meaningful changes since the previous encounter; never invent questions or advice. Comprehensive Health History preserves the longitudinal story: relevant onset, diagnoses, major illnesses, procedures, pregnancy/birth milestones, prior treatment trials and responses, resolved conditions with ongoing relevance, and supported family/social background. Preserve each distinct documented major historical milestone during final editing, including resolved problems and milestones unrelated to the current appointment; do not collapse different years or treatment changes into a single generic history bullet. Use supported event dates or periods; never infer event dates from upload dates. Order dated historical milestones chronologically and put undated background last. Retain a historical event date or period in its point text when supplied. Condition-Specific Summary explains the course and current status of each condition, including response or progression beyond the snapshot. Care Plan & Interventions captures current and previous medications/interventions, status, response, tolerance and agreed next actions, without doses or schedules. Labs & Investigations captures supported abnormal results and trends; retain explicitly planned investigations as plans, never present them as results. Each section must serve its purpose, not receive leftovers. Avoid verbatim repetition, but allow a condition in multiple sections when each adds a distinct perspective: present impact, historical onset, treatment response or investigation trend. A brief current snapshot must not erase relevant historical milestones. During drafting, checking, source audits and final editing, check longitudinal coverage as well as current concerns, decisions and actions. Omit unsupported or empty sections; do not invent history to fill them. No fixed number of history entries or pages.
        Keep all seven headings. Leave sections empty when no relevant facts qualify. Never imply a negative from missing evidence. Use bullets throughout. Omit nested headings and verbatim repetition; retain distinct historical milestones. Shorten by selecting material facts, never by dropping qualifiers from a retained fact. Supply citationIDs for factual claims. Use only the supplied evidence.
        """
    }
    /// Apply the current writing contract to newly generated content, including repaired responses.
    /// Previously saved summaries use the original document validator.
    public func validatedHandoff(_ raw: String) -> String? {
        guard let validated = validatedText(raw) else { return nil }
        let text = StorySummaryDocument.shareShorthand(validated)
        let prose = #"(?i)\b(?:is|are|was|were|has been|have been|(?:patient|clinician|doctor|provider|practitioner|midwife|parent|caregiver)\s+(?:reports?|reported|describes?|described|states?|stated|says|said|notes?|noted|indicates?|indicated)|records list|notes describe|not documented)\b"#
        for block in StorySummaryDocument.blocks(StorySummaryDocument.body(text)) {
            switch block {
            case .heading(_, level: 2): continue
            case let .bullet(line):
                let words = line.split(whereSeparator: \.isWhitespace).count
                guard words <= 18 else { return nil }
                let fields = line.components(separatedBy: " — ")
                guard fields.count == 2,
                      (1...6).contains(fields[0].split(whereSeparator: \.isWhitespace).count),
                      (1...16).contains(fields[1].split(whereSeparator: \.isWhitespace).count),
                      !line.hasSuffix("."), !line.contains(";"),
                      line.range(of: prose, options: .regularExpression) == nil else { return nil }
            default: return nil
            }
        }
        return text
    }

    /// The service may retain a checked original bullet when shortening would
    /// alter its meaning. This relaxes style only; document structure still holds.
    public func validatedServiceHandoff(_ raw:String,preservedCheckedWording:Bool)->String? {
        if !preservedCheckedWording {return validatedHandoff(raw)}
        guard let text=validatedText(raw) else{return nil}
        for block in StorySummaryDocument.blocks(StorySummaryDocument.body(text)) {
            switch block {
            case .heading(_,level:2),.bullet:continue
            default:return nil
            }
        }
        return text
    }

    public func validatedText(_ raw:String)->String? {
        let text=raw.replacingOccurrences(of:#"\[E\d+(?:\s*[,;]\s*E\d+)*\]"#,with:"",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
        // Verification can restyle a heading without changing its meaning. Normalize
        // only complete lines matching a known section; still require all seven in order.
        let normalized=text.components(separatedBy:"\n").map { line -> String in
            var label=line.trimmingCharacters(in:.whitespacesAndNewlines)
            label=label.replacingOccurrences(of:#"^#{1,6}\s+"#,with:"",options:.regularExpression)
                .trimmingCharacters(in:CharacterSet(charactersIn:"*: "))
            if let heading=sections.first(where:{$0.caseInsensitiveCompare(label) == .orderedSame}) {
                return "## "+heading
            }
            return line
        }.joined(separator:"\n")
        let headings=normalized.components(separatedBy:"\n").filter{$0.hasPrefix("## ")}.map{String($0.dropFirst(3)).trimmingCharacters(in:.whitespaces)}
        guard headings == sections,!text.isEmpty,text.count<=12000,!StorySummaryDocument.hasBrokenTable(normalized) else{return nil}
        return normalized
    }
}
private final class StorySummaryDateCache: @unchecked Sendable {
    let values=NSCache<NSString,NSString>()
    init(){values.countLimit=256}
}
public struct StorySummaryTemporal: Codable, Equatable, Sendable {
    public var role: String
    public var start: String?
    public var end: String?
    public var approximate: Bool
}
public struct StorySummaryBulletDate:Codable,Equatable,Sendable {
    public var displayOverride:String? = nil
    public var text:String
    public var labels:[String]
    public var temporal: StorySummaryTemporal? = nil
    public func displayLabel(history: Bool = false) -> String? {
        if let displayOverride { return displayOverride }
        guard let temporal else { return history ? Self.historyDisplayDate(text:text,labels:labels) : Self.displayDate(labels) }
        guard ["event", "ongoing"].contains(temporal.role), let start=temporal.start else {
            return history ? Self.historyDisplayDate(text:text,labels:[]) : Self.displayDate(labels.filter{$0.hasPrefix("Record: ")})
        }
        func format(_ date: String) -> String {
            history ? String(date.prefix(4)) : Self.displayDate(["Date: " + date]) ?? date
        }
        let first=format(start)
        let last=temporal.end.map(format)
        let period=last != nil && last != first ? first + "–" + last! : first
        return (temporal.approximate ? "c. " : "") + period
    }
    /// Show only supported event years for history; record dates are not event dates.
    /// Multiple dates stay in the text; never guess which event they refer to.
    public static func historyDisplayDate(text: String, labels: [String]) -> String? {
        if let relativeYear = relativeHistoryYear(text) { return relativeYear }
        // Citation dates can describe a later discussion, not the historical event.
        // An explicitly dated observation can establish when a state was ongoing,
        // but a later note about a past event cannot establish that event's year.
        func contains(_ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if contains(#"\b(?:before|prior to)\b"#) { return nil }
        if contains(#"\b(?:discussion|review|documentation|record|note)\b"#) && contains(#"\b(?:prior|previous|past|childhood|historical)\b"#) { return nil }
        if contains(#"\b(?:as of|documented|recorded|reported in|reported on)\b"#) {
            let pastEvent = contains(#"\b(?:history of|historical|previous|prior|past|childhood|resolved|recalled|recollection|used to|no longer|stopped|ceased)\b"#)
            let ongoingState = contains(#"\b(?:ongoing|current|currently|active|persistent|chronic|continuing|continues|still|breastfeeding|breast-feeding|lactating|pregnant)\b"#)
            guard ongoingState && !pastEvent else { return nil }
        }
        let pattern = #"\b(?:\d{4}-\d{2}-\d{2}|\d{4}\s*[-–—]\s*\d{4}|(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{4}|\d{4})\b"#
        guard let regex=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else {return nil}
        let source=text as NSString
        let matches=regex.matches(in:text,range:NSRange(location:0,length:source.length)).compactMap { match -> String? in
            let token=source.substring(with:match.range)
            let tail=source.substring(from:NSMaxRange(match.range))
            if token.count == 4, tail.range(of:#"^\s*(?:IU|mg|mcg|µg|g|mL|mmol|units|steps|calories)\b"#,options:[.regularExpression,.caseInsensitive]) != nil {return nil}
            return token
        }
        let dates=Array(Set(matches))
        return historyYear(dates.count == 1 ? dates[0] : nil)
    }
    /// Resolve only explicit year offsets with an explicit calendar anchor; never use upload dates.
    private static func relativeHistoryYear(_ text: String) -> String? {
        let pattern = #"\b(?:(about|approximately|around|roughly)\s+)?(\d{1,3})(?:\s*[-–—]\s*(\d{1,3}))?\s+years?\s+(before|prior to|after)\s+(?:(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+)?((?:19|20)\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard matches.count == 1, let match = matches.first else { return nil }
        func capture(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        guard let offset = capture(2).flatMap(Int.init), let anchor = capture(5).flatMap(Int.init) else { return nil }
        let otherOffset = capture(3).flatMap(Int.init) ?? offset
        let direction = capture(4)?.lowercased() == "after" ? 1 : -1
        let years = [anchor + direction * offset, anchor + direction * otherOffset].sorted()
        let value = years[0] == years[1] ? String(years[0]) : "\(years[0])–\(years[1])"
        return capture(1) == nil ? value : "c. " + value
    }
    private static func historyYear(_ value: String?) -> String? {
        guard let value,
              let regex = try? NSRegularExpression(pattern: #"\b\d{4}(?:\s*[-–—]\s*\d{4})?\b"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return nil }
        return String(value[range])
    }
    /// Prefer an event date; identify record-date fallbacks explicitly to preserve meaning.
    private static let cache=StorySummaryDateCache()
    public static func displayDate(_ labels:[String])->String? {
        let key=labels.sorted().joined(separator:"\u{0}") as NSString
        if let saved=cache.values.object(forKey:key) {return saved.length==0 ? nil:saved as String}
        let formats=["yyyy-MM-dd", "MMM d, yyyy", "d MMM yyyy", "MMMM d, yyyy", "d MMMM yyyy", "yyyy-MM", "MMM yyyy", "MMMM yyyy", "yyyy"]
        var events:[(Date,String)]=[]
        var records:[(Date,String)]=[]
        for label in labels where label.hasPrefix("Date: ") || label.hasPrefix("Record: ") {
            let isEvent=label.hasPrefix("Date: ")
            let raw=String(label.dropFirst(isEvent ? 6 : 8)).trimmingCharacters(in:.whitespacesAndNewlines)
            for format in formats {
                let parser=DateFormatter();parser.locale=Locale(identifier:"en_US_POSIX");parser.timeZone=TimeZone(secondsFromGMT:0);parser.dateFormat=format;parser.isLenient=false
                guard let date=parser.date(from:raw),parser.string(from:date).caseInsensitiveCompare(raw) == .orderedSame else {continue}
                let display=DateFormatter();display.locale=Locale(identifier:"en_US_POSIX");display.timeZone=parser.timeZone
                display.dateFormat=format == "yyyy" ? "yyyy" : ["yyyy-MM","MMM yyyy","MMMM yyyy"].contains(format) ? "MMM yyyy" : "d MMM yyyy"
                if isEvent {events.append((date,display.string(from:date)))}
                else {records.append((date,"Recorded " + display.string(from:date)))}
                break
            }
        }
        let result=events.max{$0.0<$1.0}?.1 ?? records.max{$0.0<$1.0}?.1
        cache.values.setObject((result ?? "") as NSString,forKey:key)
        return result
    }
}
public struct StorySharedSummary:Codable,Equatable,Sendable {
    public var practitionerPolicy:String? = nil
    public var pointReferences:[StorySummaryPointReference]? = nil
    public var bulletDates:[StorySummaryBulletDate]? = nil
    public var providerContacts:[CareTeamMember]? = nil
    public func dates(for text:String, section:String? = nil, displayDates:[StorySummaryBulletDate]? = nil)->[String] {
        let items=(displayDates ?? bulletDates ?? []).filter { StorySummaryDocument.shareShorthand($0.text)==text }
        if section == "Comprehensive Health History" {
            return [items.first?.displayLabel(history:true) ?? "—"]
        }
        return items.first?.displayLabel().map{[$0]} ?? []
    }
    public var labReadings:[StoryLabReading]? = nil
    public var patientNameEdited:Bool? = nil
    public var patientName:String? = nil
    public var templateID:String
    public var text:String
    public var generatedAt:Date
    public var evidence:[StoryEvidence]
    public init(templateID:String,text:String,generatedAt:Date=Date(),evidence:[StoryEvidence],patientName:String?=nil) {
        self.patientName=patientName;self.templateID=templateID;self.text=text;self.generatedAt=generatedAt;self.evidence=evidence
    }
}

/// Batches use encoded size, including quoting and Unicode, rather than a lossy prefix.
public enum StorySummaryBatching {
    public static func batches(_ evidence:[StoryEvidence]) throws -> [[StoryEvidence]] {
        var result:[[StoryEvidence]]=[];var batch:[StoryEvidence]=[];var bytes=2;var characters=0
        for item in evidence {
            let size=try JSONEncoder().encode(item).count+1
            guard size<=120000,item.text.count<=70000 else {throw StoryEditError.invalidMutation}
            if !batch.isEmpty && (bytes+size>120000 || characters+item.text.count>70000 || batch.count>=100) {
                result.append(batch);batch=[];bytes=2;characters=0
            }
            batch.append(item);bytes+=size;characters+=item.text.count
        }
        if !batch.isEmpty {result.append(batch)}
        return result
    }
}

/// A small shared presentation grammar; legacy paragraph summaries remain readable.
public enum StorySummaryBlock:Equatable,Sendable {
    case heading(String,level:Int)
    case paragraph(String)
    case bullet(String)
    case table(headers:[String],rows:[[String]])
}
public enum StorySummaryDocument {
    /// Read only standalone patient identity fields. Never search filenames or provider names.
    public static func recordedPatientName(in documents: [String]) -> String? {
        var names: [String: String] = [:]
        for document in documents {
            for line in document.components(separatedBy: .newlines) {
                let fields = line.split(separator: ":", maxSplits: 1)
                guard fields.count == 2 else { continue }
                let label = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
                guard ["patient", "patient name", "name of patient"].contains(label) else { continue }
                let value = fields[1].trimmingCharacters(in: .whitespaces)
                guard value.range(of: #"^[\p{L}\p{M}’'.-]+(?:[ ,]+[\p{L}\p{M}’'.-]+){1,5}$"#, options: .regularExpression) != nil else { continue }
                let parts = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count <= 2, !parts.contains("") else { continue }
                let name = parts.reversed().joined(separator: " ").split(separator: " ").joined(separator: " ")
                let key = name.lowercased()
                guard !["not documented", "not provided", "not available", "not recorded", "name withheld", "name unknown", "see above", "see chart", "de-identified"].contains(key) else { continue }
                names[key] = names[key] ?? name
                if names.count > 1 { return nil }
            }
        }
        return names.values.first
    }

    public static func patientName(in text:String)->String? {
        guard let first=text.components(separatedBy:"\n").first?.trimmingCharacters(in:.whitespaces),first.hasPrefix("Patient name: ") else{return nil}
        let name=String(first.dropFirst("Patient name: ".count)).trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,!name.lowercased().contains("not documented"),name.lowercased() != "unknown" else{return nil}
        return name
    }
    public static func body(_ text:String)->String {
        let lines=text.components(separatedBy:"\n")
        guard lines.first?.trimmingCharacters(in:.whitespaces).hasPrefix("Patient name:") == true else{return text}
        return lines.dropFirst().joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
    }
    public static func hasBrokenTable(_ text: String) -> Bool {
        parsedBlocks(text).contains { block in
            if case let .paragraph(line) = block { return line.hasPrefix("|") }
            return false
        }
    }
    public static func blocks(_ text:String)->[StorySummaryBlock] {
        var output: [StorySummaryBlock] = []
        var withinBrokenTable = false
        for block in parsedBlocks(text) {
            if case let .paragraph(line) = block, line.hasPrefix("|") {
                if !withinBrokenTable { output.append(.paragraph("Part of this table is incomplete in the saved summary.")) }
                withinBrokenTable = true
            } else {
                output.append(block)
                withinBrokenTable = false
            }
        }
        return output
    }
    /// Apply the same familiar abbreviation to the preview, PDF and new saved handoffs.
    public static func shareShorthand(_ text: String) -> String {
        var quote: Character?
        return text.components(separatedBy: "\n").map { line in
            let isQuoted = quote != nil || line.contains("“") || line.contains("”") || line.contains("\"")
            for character in line {
                if character == "“" { quote = "”" }
                else if character == "”" { quote = nil }
                else if character == "\"" { quote = quote == nil ? "\"" : nil }
            }
            guard !isQuoted, !line.hasPrefix("Patient name:") else { return line }
            return line.replacingOccurrences(of: #"(?i)\bwith\b"#, with: "w/", options: .regularExpression)
        }.joined(separator: "\n")
    }

    public static func practitionerBlocks(_ text: String, hasAbnormalLabs: Bool) -> [StorySummaryBlock] {
        var result: [StorySummaryBlock] = []
        var headings: [StorySummaryBlock] = []
        for block in blocks(shareShorthand(text)).flatMap(splitShareItems) {
            switch block {
            case let .heading(title, level):
                if level == 2 { headings.removeAll() }
                headings.append(block)
                if title != "Labs & Investigations" || !hasAbnormalLabs { continue }
            case let .bullet(value), let .paragraph(value):
                if ["not documented", "not documented in the available saved details"].contains(
                    value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) { continue }
                result.append(contentsOf: headings)
                headings.removeAll()
                result.append(block)
                continue
            case .table:
                result.append(contentsOf: headings)
                headings.removeAll()
                result.append(block)
                continue
            }
            result.append(contentsOf: headings)
            headings.removeAll()
        }
        return result
    }

    public static func topicAndNote(_ point: String) -> (topic: String, note: String) {
        guard let range = point.range(of: " — ") else { return ("", point) }
        return (String(point[..<range.lowerBound]), String(point[range.upperBound...]))
    }
    public static func displayNote(_ point: String, after previous: StorySummaryBlock?) -> String {
        guard case let .bullet(old)? = previous else { return point }
        let current = topicAndNote(point), preceding = topicAndNote(old)
        return !current.topic.isEmpty && current.topic.caseInsensitiveCompare(preceding.topic) == .orderedSame ? current.note : point
    }

    /// A read-only presentation: saved bullets and their source evidence stay unchanged.
    public static func practitionerPresentation(_ text: String, hasAbnormalLabs: Bool, bulletDates: [StorySummaryBulletDate], providerContacts: [CareTeamMember] = [], patientName: String? = nil) -> (blocks: [StorySummaryBlock], dates: [StorySummaryBulletDate]) {
        var output: [StorySummaryBlock] = []
        var dates: [StorySummaryBulletDate] = []
        func labels(for point: String) -> [String] {
            bulletDates.filter { entry in
                splitShareItems(.bullet(shareShorthand(entry.text))).contains(.bullet(point))
            }.flatMap(\.labels)
        }
        func parts(_ point: String) -> (String, String)? {
            guard let range = point.range(of: " — ") else { return nil }
            return (String(point[..<range.lowerBound]), String(point[range.upperBound...]))
        }
        func needsSeparatePoints(_ first: String, _ second: String) -> Bool {
            let states = [#"\b(?:declined|stopped|discontinued)\b"#, #"\b(?:agreed|accepted|started|used|taking)\b"#, #"\b(?:deferred|undecided|tentative|considering|unconfirmed)\b"#, #"\bresolved\b"#]
            func matches(_ body: String) -> Set<Int> {
                Set(states.indices.filter { body.range(of: states[$0], options: [.regularExpression, .caseInsensitive]) != nil })
            }
            let a = matches(first), b = matches(second)
            return !a.isEmpty && !b.isEmpty && a != b
        }
        var section = ""
        for block in practitionerBlocks(text, hasAbnormalLabs: hasAbnormalLabs) {
            if case let .heading(title, level) = block, level == 2 { section = title }
            guard case let .bullet(point) = block else { output.append(block); continue }
            let pointLabels = labels(for: point)
            let pointTemporal = bulletDates.first { entry in splitShareItems(.bullet(shareShorthand(entry.text))).contains(.bullet(point)) }?.temporal
            if let last = output.last, case let .bullet(previous) = last,
               let old = parts(previous), let next = parts(point),
               old.0.caseInsensitiveCompare(next.0) == .orderedSame,
               !needsSeparatePoints(old.1, next.1),
               (section != "Comprehensive Health History" || StorySummaryBulletDate.historyDisplayDate(text: previous, labels: []) == StorySummaryBulletDate.historyDisplayDate(text: point, labels: [])),
               let previousDates = dates.last,
               Set(previousDates.labels) == Set(pointLabels), previousDates.temporal == pointTemporal {
                let joined = old.0 + " — " + old.1.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "; " + next.1
                output[output.count - 1] = .bullet(joined)
                dates[dates.count - 1] = StorySummaryBulletDate(text: joined, labels: previousDates.labels, temporal: previousDates.temporal)
            } else {
                output.append(block)
                dates.append(StorySummaryBulletDate(text: point, labels: pointLabels, temporal: pointTemporal))
            }
        }
        // Use the same resolved year in the table and its ordering. Unknown date
        // metadata must not leave explicitly dated history stranded out of order.
        if let heading = output.firstIndex(of: .heading("Comprehensive Health History", level: 2)) {
            let end = output[(heading + 1)...].firstIndex { if case .heading = $0 { return true }; return false } ?? output.endIndex
            let range = (heading + 1)..<end
            let entries = output[range].enumerated().map { offset, block -> (Int, StorySummaryBlock, Int?) in
                guard case let .bullet(text) = block,
                      let label = dates.first(where: { $0.text == text })?.displayLabel(history: true),
                      let match = label.range(of: #"\b(?:19|20)\d{2}\b"#, options: .regularExpression),
                      let year = Int(label[match]) else { return (offset, block, nil) }
                return (offset, block, year)
            }.sorted { a, b in
                if a.2 != b.2 { return (a.2 ?? Int.max) < (b.2 ?? Int.max) }
                return a.0 < b.0
            }
            output.replaceSubrange(range, with: entries.map { $0.1 })
        }
        // Contact fields are rendered verbatim from the frozen local roster, never
        // generated or guessed from a person's name or profession.
        func identity(_ name: String) -> String {
            name.lowercased().replacingOccurrences(of: #"^(?:dr\.?|mr\.?|mrs\.?|ms\.?)\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var inProviders=false
        output=output.compactMap { block in
            if case let .heading(title,level)=block,level==2 {inProviders=title == "Care Coordination Summary"}
            guard inProviders,case let .bullet(text)=block else{return block}
            let fields=topicAndNote(text),key=identity(fields.topic)
            if let patientName,!patientName.isEmpty,(key==identity(patientName) || key.hasPrefix(identity(patientName)+", ")) {return nil}
            let matches=providerContacts.filter { contact in
                let name=identity(contact.name),role=contact.role.trimmingCharacters(in:.whitespacesAndNewlines)
                return !name.isEmpty && (key==name || (!role.isEmpty && key==identity(contact.name+", "+role)))
            }
            guard matches.count==1,let contact=matches.first else{return block}
            let role=contact.role.trimmingCharacters(in:.whitespacesAndNewlines)
            let title=contact.name+(role.isEmpty ? "" : ", "+role)
            var details=[String]()
            if !contact.organization.isEmpty && !fields.note.localizedCaseInsensitiveContains(contact.organization) {details.append(contact.organization)}
            details.append(fields.note)
            for (label,value) in [("Phone",contact.phone),("Email",contact.email),("Address",contact.address ?? "")] where !value.isEmpty && !fields.note.contains(value) {details.append(label+": "+value)}
            let revised=title+" — "+details.filter{!$0.isEmpty}.joined(separator:"; ")
            for i in dates.indices where dates[i].text==text {dates[i].text=revised}
            return .bullet(revised)
        }
        // Removing a mistaken patient entry must not leave an empty section.
        output=output.enumerated().filter { index,block in
            guard case .heading(_,2)=block else{return true}
            return index+1<output.count && { if case .heading(_,2)=output[index+1] {return false};return true }()
        }.map(\.element)
        return (output, dates)
    }

    static func splitShareItems(_ block: StorySummaryBlock) -> [StorySummaryBlock] {
        let text: String
        switch block {
        case let .bullet(value), let .paragraph(value): text = value
        default: return [block]
        }
        // Keep quoted language and parenthetical qualifications together.
        var quote: Character?
        var depth = 0
        var items: [String] = []
        var start = text.startIndex
        for index in text.indices {
            let character = text[index]
            if let closing = quote {
                if character == closing { quote = nil }
                continue
            }
            if character == "“" { quote = "”" }
            else if character == "\"" { quote = "\"" }
            else if character == "(" || character == "[" { depth += 1 }
            else if character == ")" || character == "]" { depth = max(0, depth - 1) }
            else if character == ";", depth == 0 {
                items.append(String(text[start..<index]))
                start = text.index(after: index)
            }
        }
        guard !items.isEmpty else { return [block] }
        items.append(String(text[start...]))
        let topic = items[0].range(of: " — ").map { String(items[0][..<$0.upperBound]) }
        return items.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let value = topic != nil && !trimmed.contains(" — ") ? topic! + trimmed : trimmed
            return .bullet(value)
        }
    }

    private static func parsedBlocks(_ text:String)->[StorySummaryBlock] {
        let lines=text.components(separatedBy:"\n").filter{!$0.trimmingCharacters(in:.whitespaces).isEmpty};var result:[StorySummaryBlock]=[];var index=0
        func cells(_ line:String)->[String]? {
            let trimmed=line.trimmingCharacters(in:.whitespaces)
            guard trimmed.hasPrefix("|"),trimmed.hasSuffix("|") else{return nil}
            return trimmed.dropFirst().dropLast().components(separatedBy:"|").map{$0.trimmingCharacters(in:.whitespaces)}
        }
        while index<lines.count {
            let line=lines[index].trimmingCharacters(in:.whitespaces)
            if let header=cells(line), (2...4).contains(header.count),index+1<lines.count,
               let divider=cells(lines[index+1]),divider.count==header.count,
               divider.allSatisfy({$0.replacingOccurrences(of:":",with:"").allSatisfy{$0=="-"} && $0.filter{$0=="-"}.count>=3}) {
                var rows:[[String]]=[];var end=index+2
                while end<lines.count,let row=cells(lines[end]),row.count==header.count {rows.append(row);end+=1}
                if !rows.isEmpty {result.append(.table(headers:header,rows:rows));index=end;continue}
            }
            if line.hasPrefix("### ") {result.append(.heading(String(line.dropFirst(4)),level:3))}
            else if line.hasPrefix("## ") {result.append(.heading(String(line.dropFirst(3)),level:2))}
            else if ["- ", "* ", "• "].contains(where: { line.hasPrefix($0) }) {
                result.append(.bullet(String(line.dropFirst(2))))
            }
            else if !line.isEmpty {result.append(.paragraph(line))}
            index+=1
        }
        return result
    }
}
