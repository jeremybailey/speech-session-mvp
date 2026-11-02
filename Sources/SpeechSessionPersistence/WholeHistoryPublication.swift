import Foundation

/// Source-linked B output. Inclusion never implies independent source checking.
public struct WholeHistoryPublication: Sendable {
    public static let version = "whole-history-b-main-v1"
    public var entries: [UUID: [SummaryEntry]]
    public var topics: [HealthTopic]
    public var overview: String?
    public init(entries: [UUID: [SummaryEntry]], topics: [HealthTopic], overview: String?) {
        self.entries = entries; self.topics = topics; self.overview = overview
    }
    public static func fingerprint(_ sessions: [Session]) -> String {
        SummaryVerification.hash(sessions.filter { !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.processingState != .failed && $0.processingState != .transcribing }
            .map { $0.id.uuidString + SummaryVerification.hash($0.transcript) }.sorted().joined(separator: "|"))
    }
    public static func careCard(_ input: CarePlanCardInput) -> CarePlanCard {
        CarePlanCard(id: input.id, fingerprint: input.fingerprint, sessionID: input.session.id,
            conditionID: input.conditionID, practitioner: nil, practitionerQuotation: nil,
            lines: input.generatedEntries.map { entry in
                CarePlanCard.Line(memberIDs: [entry.id], text: ([CareInstructionPresentation.instruction(entry)] + [entry.evidence?.careInstruction?.schedule, entry.evidence?.careInstruction?.consideration].compactMap { $0 }.filter { !$0.isEmpty && !entry.title.localizedCaseInsensitiveContains($0) }).joined(separator: " · "),
                    bucket: entry.evidence?.careInstruction?.bucket ?? (entry.category == .followUp ? .followUp : .carePlan),
                    owner: entry.evidence?.careInstruction?.owner, quotation: entry.supportingExcerpt ?? "")
            })
    }
}
