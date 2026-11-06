import Foundation

/// Local display copies only. Never changes source facts, clinical identity,
/// verification, relationships or model requests. No clinical inference.
public enum BArtifactPresentation {
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: $0.numberOfRanges > 1 ? 1 : 0), in: text).map { trim(String(text[$0])) }
        }
    }
    public static func isLabReportMetadata(_ entry: SummaryEntry) -> Bool {
        guard BClinicalPresentation.applies(entry), entry.category == .testsAndLabs else { return false }
        let title = trim(entry.title)
        if title.range(of: #"(?i)^(?:hours fasting|fasting hours|fasting duration)(?:\s*:|$)"#, options: .regularExpression) != nil {
            return true
        }
        guard !entry.fields.contains(where: { $0.label.caseInsensitiveCompare("Result") == .orderedSame && !trim($0.value).isEmpty }) else { return false }
        return title.range(of: #"(?i)^lab report (?:notes?|cautions?|advises?|states?|says|comment(?:s)?)[^\n]*(?:different instruments|different assays|instrument differences)"#, options: .regularExpression) != nil
    }

    public static func display(_ entry: SummaryEntry) -> SummaryEntry {
        var rendered = render(entry)
        guard BClinicalPresentation.applies(entry), entry.category == .testsAndLabs,
              rendered.title.caseInsensitiveCompare(entry.category.displayTitle) == .orderedSame else { return rendered }

        let sourceText = [entry.title, entry.details].map(trim).first {
            !$0.isEmpty && $0.caseInsensitiveCompare(entry.category.displayTitle) != .orderedSame
        } ?? ""
        let orderName = matches(#"(?i)^([\p{L}][\p{L}\d /&()–-]{1,69}?)\s+(?:test\s+)?ordered\b"#, sourceText).first
        var candidate = rendered
        candidate.title = sourceText
        rendered.title = lab(candidate)?.title ?? orderName.map { $0 + " (ordered)" } ?? "Lab entry · check source"
        return rendered
    }

    private static func render(_ entry: SummaryEntry) -> SummaryEntry {
        guard BClinicalPresentation.applies(entry), entry.category != .medications else { return entry }
        var result = entry
        result.evidence?.practitioner = BClinicalPresentation.namedPractitioner(entry.evidence?.practitioner)
        result.evidence?.eventDate = entry.evidence?.eventDate.flatMap { trim($0).isEmpty ? nil : $0 }
        result.details = entry.details.components(separatedBy: .newlines).filter {
            !$0.hasPrefix("Recorded status:") && !$0.hasPrefix("Attribution:") && !$0.hasPrefix("Recorded date:")
        }.joined(separator: "\n")
        // Absent values must not produce empty Date/Practitioner rows.
        result.fields = entry.fields.filter { !trim($0.value).isEmpty && !HealthStoryText.isInternalField($0.label) }
        if entry.category == .testsAndLabs {
            let placeholder = #"(?i)[;,]\s*(?:each has )?abnormality\s*[:=]?\s*["“']?[-–—]["”']?(?=\s*[.;,]|\s*$)"#
            result.title = result.title.replacingOccurrences(of: placeholder, with: "", options: .regularExpression)
            result.details = result.details.replacingOccurrences(of: placeholder, with: "", options: .regularExpression)
        }
        if entry.category == .testsAndLabs, let panel = labPanel(result) { return panel }
        if entry.evidence?.artifactSchema == StructuredArtifact.version {
            let typed=StructuredArtifact.display(result)
            return entry.category == .practitionerContact ? structuredContact(typed) : typed
        }
        if entry.category == .practitionerContact { return contact(result) }
        // Actions already have their own instruction/schedule/owner renderer.
        guard !CareInstructionPresentation.applies(entry) else { return result }
        if entry.category == .testsAndLabs, let lab = lab(result) { return lab }
        if entry.category == .vaccinations { return vaccination(result) }
        let parsed = labelled(entry.title + "\n" + result.details)
        let allowed: Set<String>
        switch entry.category {
        case .testsAndLabs: allowed = ["Test", "Result", "Units", "Reference range", "Specimen", "Interpretation"]
        case .vaccinations: allowed = ["Vaccine", "Dose", "Route", "Site", "Lot", "Record date"]
        case .allergies: allowed = ["Allergen", "Reaction", "Severity", "Record status"]
        case .symptoms, .chiefComplaint: allowed = ["Symptom", "Onset", "Duration", "Severity", "Location", "Frequency"]
        case .findings: allowed = ["Finding", "Result", "Location", "Interpretation"]
        case .biopsychosocialContext, .otherNotes: allowed = ["Topic", "Context"]
        default: allowed = []
        }
        for field in parsed where allowed.contains(field.label) && !result.fields.contains(where: { $0.label == field.label && $0.value == field.value }) { result.fields.append(field) }
        let primary = ["Test", "Vaccine", "Allergen", "Symptom", "Finding", "Topic"]
        if let heading = parsed.first(where: { primary.contains($0.label) && allowed.contains($0.label) }), heading.value.count <= 90 {
            result.title = heading.value
            // Preserve every clinical qualifier, including those not recognized as fields.
            result.details = [entry.title, result.details].filter { !trim($0).isEmpty }.joined(separator: "\n")
        } else {
            let title = trim(result.title)
            let cleaned = title.replacingOccurrences(of: #"(?i)^(?:(?:the patient|patient)\s+(?:reports|reported|states|describes|says)|reports(?: that)?)\s+"#, with: "", options: .regularExpression)
            if cleaned.count > 100 || cleaned.contains("\n") {
                result.title = entry.category.displayTitle
                result.details = [title, result.details].filter { !trim($0).isEmpty }.joined(separator: "\n")
            } else { result.title = cleaned }
        }
        return result
    }

    private static func labPanel(_ entry: SummaryEntry) -> SummaryEntry? {
        guard entry.fields.isEmpty, labelled(entry.title).isEmpty else { return nil }
        let heading = matches(#"^([\p{L}][\p{L} /&()–-]{1,59}):"#, entry.title).first
        let body = heading.flatMap { _ in entry.title.firstIndex(of: ":") }
            .map { String(entry.title[entry.title.index(after: $0)...]) } ?? entry.title
        let parts = body.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: #";(?![^()]*\))"#, with: "\n", options: .regularExpression)
            .split(separator: "\n").map { trim(String($0)) }
        var measurements = parts.filter { !$0.isEmpty }
        var reportNote: String?
        if let last = measurements.last, last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "no abnormality indicated" {
            reportNote = measurements.removeLast()
        }
        guard measurements.count > 1 || (heading != nil && !measurements.isEmpty) else { return nil }
        let pattern = #"^(.+?)\s+([<>≤≥]?\s*\d+(?:[.,]\d+)?\s*[^()]*)\s*\(([^()]+)\)\.?$"#
        let fields = measurements.compactMap { measurement -> SummaryEntryField? in
            let text = trim(String(measurement))
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let name = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text),
                  let reference = Range(match.range(at: 3), in: text) else { return nil }
            let result = trim(String(text[value]))
                .replacingOccurrences(of: #"(?i)[x×]10\*\*(\d+)"#, with: "×10^$1", options: .regularExpression)
            let range = trim(String(text[reference])).replacingOccurrences(of: #"(?i)^reference\s+"#, with: "", options: .regularExpression)
            return SummaryEntryField(label: trim(String(text[name])), value: result + " (ref. " + range + ")")
        }
        var panel = entry
        guard fields.count == measurements.count else {
            guard let heading else { return nil }
            panel.title = heading
            panel.details = [trim(body), entry.details].filter { !$0.isEmpty }.joined(separator: "\n")
            return panel
        }
        panel.title = heading?.caseInsensitiveCompare("CBC") == .orderedSame
            ? "Complete blood count (CBC)" : heading ?? "Lab measurements"
        panel.fields = fields
        panel.details = [reportNote ?? "", entry.details].filter { !$0.isEmpty }.joined(separator: "\n")
        return panel
    }

    /// The existing lab report syntax has an explicit value/reference boundary.
    /// Do not interpret abnormality, convert units or select a newer result.
    private static func lab(_ entry: SummaryEntry) -> SummaryEntry? {
        let pattern = #"^(.{2,70}?)\s+([<>≤≥]?\s*\d+(?:[.,]\d+)?)(?:\s*([^\n;(]+?))?\s*(?:\((?i:reference)\s+([^)]*)\))?(?=;|\.(?:\s|$)|$)"#
        guard let regex = try? NSRegularExpression(pattern:pattern),
              let match = regex.firstMatch(in:entry.title,range:NSRange(entry.title.startIndex...,in:entry.title)),
              let full = Range(match.range,in:entry.title) else { return nil }
        func value(_ i:Int) -> String? {
            guard let range=Range(match.range(at:i),in:entry.title) else { return nil }
            let value=trim(String(entry.title[range])); return value.isEmpty ? nil : value
        }
        guard let name=value(1), let result=value(2), name.rangeOfCharacter(from:CharacterSet(charactersIn:":;\n")) == nil else { return nil }
        let unit=value(3)
        if let unit {
            // A number inside a test name (e.g. 25-hydroxy) is not its result.
            guard unit.range(of:#"^(?:%|(?:[A-Za-zµμ]+|[x×]?\s*10\^?\d+)(?:/[A-Za-zµμ0-9.^]+){0,2})$"#,options:.regularExpression) != nil else { return nil }
        } else if value(4) == nil { return nil }
        var output=entry;output.title=name
        output.fields += [("Result",result),("Units",value(3)),("Reference range",value(4))].compactMap { label,value in
            value.map { SummaryEntryField(label:label,value:$0) }
        }
        let tail=String(entry.title[full.upperBound...]).trimmingCharacters(in:CharacterSet(charactersIn:";. \n"))
        output.details=[tail,entry.details].filter { !trim($0).isEmpty }.joined(separator:"\n")
        return output
    }
    private static func vaccination(_ entry: SummaryEntry) -> SummaryEntry {
        // Labelled rows use the generic projection below. Event status is a record
        // statement; a pharmacy fill must never become proof of administration.
        var output=entry
        if entry.title.hasPrefix("Fill: "), let end=entry.title.firstIndex(of:";") {
            output.title=trim(String(entry.title[entry.title.index(entry.title.startIndex,offsetBy:6)..<end]))
            output.fields.append(.init(label:"Record type",value:"Dispensing record"))
            output.details=[entry.title,entry.details].filter { !trim($0).isEmpty }.joined(separator:"\n")
        } else if let regex=try? NSRegularExpression(pattern:#"^(.{1,90}? vaccine) recorded as (.+?)\.?$"#),
                  let match=regex.firstMatch(in:entry.title,range:NSRange(entry.title.startIndex...,in:entry.title)),
                  let name=Range(match.range(at:1),in:entry.title),let status=Range(match.range(at:2),in:entry.title) {
            output.title=String(entry.title[name]);output.fields.append(.init(label:"Recorded status",value:String(entry.title[status])))
        } else {
            let parsed=labelled(entry.title+"\n"+entry.details)
            let allowed:Set<String>=["Vaccine","Dose","Route","Site","Lot","Record date"]
            output.fields += parsed.filter { allowed.contains($0.label) }
            if let name=parsed.first(where:{$0.label=="Vaccine"}) { output.title=name.value;output.details=[entry.title,entry.details].filter{!trim($0).isEmpty}.joined(separator:"\n") }
            else if entry.title.count>100 {output.title="Vaccinations";output.details=[entry.title,entry.details].filter{!trim($0).isEmpty}.joined(separator:"\n")}
        }
        return output
    }

    private static func structuredContact(_ entry: SummaryEntry) -> SummaryEntry {
        var result=entry
        result.title=entry.fields.first(where:{$0.label=="Name"})?.value ?? "Care team contact — check original"
        result.evidence?.practitioner=nil
        // The sparse context field carries the role/uncertainty; the full original
        // proposal remains in source history. Do not repeat metadata prose here.
        return result
    }

    /// Recognize labelled syntax only; unlabelled clinical prose stays intact.
    private static func labelled(_ text: String) -> [SummaryEntryField] {
        let labels = ["name":"Name", "organization":"Organization", "org":"Organization", "clinic":"Organization",
                      "role":"Role or specialty", "specialty":"Role or specialty", "role or specialty":"Role or specialty",
                      "phone":"Phone", "email":"Email", "address":"Address", "test":"Test", "result":"Result", "units":"Units",
                      "reference range":"Reference range", "specimen":"Specimen", "interpretation":"Interpretation",
                      "vaccine":"Vaccine", "dose":"Dose", "route":"Route", "site":"Site", "lot":"Lot", "record date":"Record date",
                      "allergen":"Allergen", "reaction":"Reaction", "severity":"Severity", "record status":"Record status",
                      "symptom":"Symptom", "onset":"Onset", "duration":"Duration", "location":"Location", "frequency":"Frequency",
                      "finding":"Finding", "topic":"Topic", "context":"Context"]
        let split = text.replacingOccurrences(of: #"[;|]\s*(?=(?i:name|organization|org|clinic|role|specialty|role or specialty|phone|email|address|test|result|units|reference range|specimen|interpretation|vaccine|dose|route|site|lot|record date|allergen|reaction|severity|record status|symptom|onset|duration|location|frequency|finding|topic|context):)"#, with: "\n", options: .regularExpression)
        return split.components(separatedBy: .newlines).compactMap { line in
            guard let colon = line.firstIndex(of: ":"), let label = labels[trim(String(line[..<colon])).lowercased()] else { return nil }
            let value = trim(String(line[line.index(after:colon)...]))
            return value.isEmpty ? nil : .init(label: label, value: value)
        }
    }
    private static func contact(_ entry: SummaryEntry) -> SummaryEntry {
        var result = entry
        result.details = entry.title == entry.details ? entry.details : [entry.title,entry.details].filter{!trim($0).isEmpty}.joined(separator:"\n")
        let raw = entry.title + "\n" + entry.details
        let allowed: Set<String> = ["Name", "Organization", "Role or specialty", "Phone", "Email", "Address", "Context"]
        var fields = entry.fields + (entry.evidence?.contactFields ?? []) + labelled(raw).filter { allowed.contains($0.label) }
        let explicitNames = fields.filter { $0.label.lowercased() == "name" }.map(\.value)
        // Case-sensitive name tokens stop before narrative words such as 'as',
        // 'was' and 'treating'. Multiple names never become one person's card.
        let names = matches(#"\b((?:Dr\.?|Doctor|Nurse)\s+\p{Lu}[\p{L}'’.-]*(?:\s+(?!(?i:Phone|Email|Address|Clinic|Centre|Center|MD|OD|FRCPC|FRCSC)\b)\p{Lu}[\p{L}'’.-]*){0,3})"#, entry.title) + matches(#"(?i:electronically signed by|signed by|reported by|referral to)\s+(\p{Lu}[\p{L}'’.-]*(?:\s+(?!(?i:MD|OD|FRCPC|FRCSC)\b)\p{Lu}[\p{L}'’.-]*){0,3})"#, entry.title)
        let organization = matches(#"^(.{1,90}?)\s+(?i:is named as (?:pharmacy|clinic|hospital|organization)\b)"#, entry.title).first
        let unique = Array(Set(explicitNames.isEmpty ? names : explicitNames)).sorted()
        let name: String?
        if unique.count == 1 { name = unique[0] }
        else if unique.isEmpty, let organization { name = organization }
        else if unique.isEmpty, entry.title.count <= 90, !entry.title.contains("\n"),
                entry.title.range(of: #"(?i)\b(reports?|identifies|invoice|patient|treating|performed|referred|called)\b|[:;]"#, options:.regularExpression) == nil { name = entry.title }
        else { name = nil }
        result.title = name ?? "Care team contact — check original"
        if !fields.contains(where: { $0.label.lowercased() == "name" }), let name { fields.append(.init(label:"Name",value:name)) }
        // Only parse channels from this fact, never from its broad source excerpt:
        // a passage can contain several clinicians and their separate addresses.
        for (label, pattern) in [("Email", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
                                 ("Phone", #"(?<!\d)(?:\+?1[ .-]?)?(?:\(\d{3}\)|\d{3})[ .-]?\d{3}[ .-]?\d{4}(?:\s*(?:ext\.?|x)\s*\d+)?(?!\d)"#)] {
            // A channel cannot be assigned when this row mentions several people.
            let values = Set(matches(pattern, raw))
            if unique.count <= 1, values.count == 1, !fields.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
                fields.append(.init(label:label,value:values.first!))
            }
        }
        if unique.count > 1 {
            result.title="Contacts listed on record"
            fields.append(.init(label:"Names listed",value:unique.joined(separator:"\n")))
            // No person is selected as prescriber or owner from a printed roster.
            result.details=entry.title.split(separator:";",maxSplits:1).dropFirst().map(String.init).joined(separator:";")
        } else if let name {
            func add(_ label:String,_ value:String?) {
                guard let value, !trim(value).isEmpty, !fields.contains(where:{$0.label.caseInsensitiveCompare(label) == .orderedSame}) else{return}
                fields.append(.init(label:label,value:trim(value)))
            }
            add("Address",matches(#"(?i)(?:clinic |postal )?address(?: is|:)\s*(.+?)(?:;|$)"#,raw).first)
            if let range=entry.title.range(of:name) {
                let tail=String(entry.title[range.upperBound...])
                let role=matches(#"^\s+as\s+(.+?)(?:;|$)"#,tail).first
                add("Role or specialty",role?.trimmingCharacters(in:CharacterSet(charactersIn:". ")))
                // Only directly adjacent, explicitly organization-shaped values.
                let clauses=tail.components(separatedBy:CharacterSet(charactersIn:",;"))
                let organizations=clauses.map(trim).filter {
                    $0.range(of:#"^[\p{Lu}][\p{L}\d '\-’&.]{1,85}(?:Centre|Center|Clinic|Hospital|Pharmacy|Drug Mart)(?:\s*#\d+)?\.?$"#,options:.regularExpression) != nil
                }
                if Set(organizations).count==1 {add("Organization",organizations.first?.trimmingCharacters(in:CharacterSet(charactersIn:". ")))}
                if tail.range(of:#"^\s+(?:was involved|who |performed |treated |provided )"#,options:.regularExpression) != nil {
                    add("Recorded involvement",trim(tail))
                }
            }
            let reviews=entry.title.split(separator:";",maxSplits:1).dropFirst().map(String.init)
            if let review=reviews.first, review.localizedCaseInsensitiveContains("unclear") || review.localizedCaseInsensitiveContains("transcribed") {add("Review",trim(review))}
            // Identifier boilerplate is provenance, not contact details. Full wording
            // remains in immutable source history. Keep unexplained prose visible.
            let identifier = entry.title.range(of:#"(?i)^(?:prescription(?: image| label)? (?:identifies|names|lists)|(?:eye )?invoice identifies|(?:patient )?identifies|patient reports|label (?:identifies|names|lists))\s+"#,options:.regularExpression) != nil
            let recovered = fields.contains { ["Role or specialty","Organization","Address","Recorded involvement"].contains($0.label) }
            if identifier && recovered {result.details=entry.details}
        }
        var seen = Set<String>()
        result.fields = fields.filter { !trim($0.value).isEmpty && seen.insert($0.label.lowercased()+"|"+$0.value.lowercased()).inserted }
        // Role/history is clinically meaningful; retain the full statement as
        // body text rather than a multi-line bold contact name.
        if unique.count<=1 && result.details == entry.details && !fields.contains(where:{["Role or specialty","Organization","Address","Recorded involvement"].contains($0.label)}) {
            result.details = trim(entry.title) == result.title ? entry.details : [entry.title,entry.details].filter { !trim($0).isEmpty }.joined(separator:"\n")
        }
        result.evidence?.practitioner = nil // The contact itself is not its own attribution.
        return result
    }
}

/// Every selected fact must have an export group, including unknown statuses.
public enum HealthFactExportPresentation {
    public static func statuses(_ facts: [HealthFact]) -> [String] {
        let present = Set(facts.map { CareInstructionPresentation.status($0) })
        let ordered = ["Current", "Completed", "Paused", "Non-current", "Current use unknown", "Status unknown"]
        return ordered.filter { present.contains($0) } + present.subtracting(ordered).sorted()
    }
}
