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
        Write a selective two-page handoff. Aim for 2200–3000 characters including headings, shorter for sparse evidence. Give each fact one home. Write each section as concise bullet points. Start each point on its own line with '- '. Use one material finding or action per bullet and keep its qualifiers together.
        Clinical Snapshot: one or two bullets on the main concerns, functional impact and patient priorities.
        Care Coordination Summary: documented allergies or sensitivities and who is coordinating care.
        Appointment Preparation Brief: recorded reason, patient questions or changes requiring discussion.
        Comprehensive Health History: relevant dated milestones and background. Never infer clinical dates from upload dates.
        Condition-Specific Summary: material course or status beyond the snapshot. Keep suspected, excluded and established conditions distinct.
        Care Plan & Interventions: document current medications and adopted actions here once. Keep dose, units, timing, conditions, attribution and conflicting regimens together. Distinguish recommendations from adopted actions and previous treatments. Attribute reported responses.
        Labs & Investigations: relevant dated results, units, supplied ranges and documented interpretation or follow-up. Do not infer trends.
        Keep all seven headings. Where evidence is missing use “Not documented.” Never imply a negative from missing evidence. Use at most one short Markdown table for genuinely comparable rows, with a header, separator and consistent columns. Omit nested headings and repeated history. Shorten by selecting material facts, never by dropping qualifiers from a retained fact. Supply citationIDs for factual claims. Use only the supplied evidence.
        """
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
public struct StorySharedSummary:Codable,Equatable,Sendable {
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
