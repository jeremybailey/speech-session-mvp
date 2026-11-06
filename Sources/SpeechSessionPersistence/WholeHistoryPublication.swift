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
    /// A complete category disappearing from the same unchanged original needs review.
    /// Do not infer categories from keywords or copy individual facts into two categories.
    public static let continuityCategories:Set<SummaryEntryCategory> = [.testsAndLabs,.vaccinations,.biopsychosocialContext]
    public static func sourceLinkedEntries(_ entries:[SummaryEntry], session:Session) -> [SummaryEntry] {
        let hash=SummaryVerification.hash(session.transcript)
        return entries.filter {entry in
            guard !entry.isDeleted, entry.origin != .userAdded, entry.origin != .userEdited,
                  entry.sourceSessionID==session.id,let a=entry.evidence?.assessment,
                  a.admission == .sourceLinked,a.sourceHash==hash,a.contentHash==SummaryVerification.contentHash(entry),
                  !a.citations.isEmpty,a.citations.allSatisfy({!$0.excerpt.isEmpty && session.transcript.contains($0.excerpt)}) else {return false}
            return true
        }
    }
    public static func missingCategories(previous:[SummaryEntry],generated:[SummaryEntry],session:Session) -> Set<SummaryEntryCategory> {
        let edited=Set(generated.filter{$0.origin == .userAdded || $0.origin == .userEdited || $0.isDeleted}.map(\.id))
        let old=Set(sourceLinkedEntries(previous,session:session).filter{!edited.contains($0.id)}.map(\.category)).intersection(continuityCategories)
        let new=Set(generated.filter{!$0.isDeleted && $0.evidence?.assessment?.admission != .superseded}.map(\.category))
        return old.subtracting(new)
    }
    /// Review tokens bind a decision to this source and both exact projections.
    public static func categoryReview(previous:[SummaryEntry],generated:[SummaryEntry],session:Session) -> WholeHistoryCategoryReview? {
        let missing=missingCategories(previous:previous,generated:generated,session:session)
        guard !missing.isEmpty else {return nil}
        func signature(_ entries:[SummaryEntry])->String {
            entries.map{$0.id.uuidString+":"+SummaryVerification.contentHash($0)+":"+$0.origin.rawValue+":"+String($0.isDeleted)}.sorted().joined(separator:"|")
        }
        let token=SummaryVerification.hash(session.id.uuidString+SummaryVerification.hash(session.transcript)+signature(previous)+signature(generated))
        return WholeHistoryCategoryReview(session:session,previous:sourceLinkedEntries(previous,session:session).filter{missing.contains($0.category)},generated:generated,missingCategories:missing,token:token)
    }
    /// Recover one whole prior source projection, avoiding a mix of duplicate old/new facts.
    public static func categoryRecovery(for session:Session) -> [SummaryEntry]? {
        let current=session.summaryEntries ?? []
        if let run=session.summaryRun,run.stage == .complete,run.promptVersion==version,
           run.sourceHash==SummaryVerification.hash(session.transcript),run.categoryChangeReviewToken?.isEmpty==false {return nil}
        guard let revision=session.summaryRevisions?.last else {return nil}
        let prior=sourceLinkedEntries(revision.entries,session:session)
        return missingCategories(previous:prior,generated:current,session:session).isEmpty ? nil:prior
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

/// Accepting organization changes never changes the source-linked trust level.
public struct WholeHistoryCategoryReview: Identifiable {
    public var id:UUID {session.id}
    public let session:Session
    public let previous:[SummaryEntry]
    public let generated:[SummaryEntry]
    public let missingCategories:Set<SummaryEntryCategory>
    public let token:String
}
