import Foundation

/// Optional contact fields cannot veto an independently supported contact identity.
public enum ContactFieldVerification {
    public static func drafts(identity: SummaryEntry, extracted: [SummaryEntry]) -> [SummaryEntry] {
        var core = identity
        core.fields = [.init(label: "Name", value: core.title)]
        core.details = ""
        core.evidence = nil
        var result = [core]
        var seen = Set<String>()
        for field in extracted.flatMap(\.fields) {
            let key = field.label.lowercased()
            guard ["organization", "role or specialty", "phone", "email", "address"].contains(key),
                  !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(key + "|" + field.value).inserted else { continue }
            var item = core
            item.id = UUID()
            item.fields.append(field)
            result.append(item)
        }
        return result
    }

    /// Combines only separately checked fields from the same explicitly identified contact.
    /// Conflicting accepted values stay unset rather than choosing an arbitrary winner.
    public static func assemble(identityID: UUID, reviewed: [SummaryEntry], source: String) -> SummaryEntry? {
        guard var core = reviewed.first(where: { $0.id == identityID }) else { return nil }
        guard SummaryVerification.isVisible(core, source: source) else { return core }
        let candidates = reviewed.filter { $0.id != identityID && $0.title == core.title }
        let accepted = candidates.filter { SummaryVerification.isVisible($0, source: source) }
        let fields = accepted.flatMap { $0.fields.filter { $0.label != "Name" } }
        let groups = Dictionary(grouping: fields, by: { $0.label.lowercased() })
        let unambiguous = groups.values.compactMap { values -> SummaryEntryField? in
            Set(values.map(\.value)).count == 1 ? values.first : nil
        }.sorted { $0.label < $1.label }
        core.fields += unambiguous
        var citations = core.evidence?.assessment?.citations ?? []
        for entry in accepted where entry.fields.filter({ $0.label != "Name" }).allSatisfy({ field in unambiguous.contains { $0.label == field.label && $0.value == field.value } }) {
            citations += entry.evidence?.assessment?.citations ?? []
        }
        let omitted = Set(candidates.flatMap { $0.fields.filter { $0.label != "Name" }.map(\.label) }).subtracting(unambiguous.map(\.label)).sorted()
        core.evidence?.contactFields = core.fields
        core.evidence?.omittedFields = omitted.isEmpty ? nil : omitted
        if !omitted.isEmpty {
            core.reviewReason = "Could not confirm: " + omitted.joined(separator: ", ") + ". The supported contact details are shown."
            core.evidence?.reviewReason = core.reviewReason
        }
        let fullyChecked = core.evidence?.assessment?.admission == .supported && accepted.allSatisfy { $0.evidence?.assessment?.admission == .supported }
        core.evidence?.assessment = nil
        let hash = SummaryVerification.contentHash(core)
        core.evidence?.assessment = SummaryAssessment(admission: fullyChecked ? .supported : .sourceLinked, reason: fullyChecked ? "Name and each included contact field checked independently against the original." : "Contact extracted from the original; automated checking is incomplete.", sourceHash: SummaryVerification.hash(source), contentHash: hash, citations: citations)
        return core
    }
}
