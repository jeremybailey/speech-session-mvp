import Foundation

/// Reconciles a newly generated visit card set with cards the user already edited, added, or deleted.
public enum SummaryEntryMerge {
    /// Keep user-added cards, deleted tombstones, and user edits; replace unmatched generated cards.
    public static func merging(generated: [SummaryEntry], existing: [SummaryEntry]?, supersedeUnmatchedGenerated: Bool = false) -> [SummaryEntry] {
        guard let existing, !existing.isEmpty else { return generated }

        var consumed: Set<UUID> = []
        var result: [SummaryEntry] = []
        result.reserveCapacity(generated.count + existing.count)

        for gen in generated {
            if let old = firstMatch(of: gen, in: existing, excluding: consumed) {
                consumed.insert(old.id)
                result.append(reconcile(generated: gen, existing: old))
            } else {
                result.append(gen)
            }
        }

        for old in existing where !consumed.contains(old.id) {
            if old.origin == .userAdded || old.origin == .userEdited || old.isDeleted || old.evidence?.instructionIdentity != nil || old.evidence?.factIdentity != nil {
                var retained = old
                if supersedeUnmatchedGenerated, old.origin != .userAdded, old.origin != .userEdited, !old.isDeleted {
                    if retained.evidence == nil { retained.evidence = ClinicalEvidence() }
                    let fingerprint = SummaryVerification.contentHash(retained)
                    retained.evidence?.assessment = SummaryAssessment(admission: .superseded, reason: "Replaced during source reassessment",
                        sourceHash: old.evidence?.assessment?.sourceHash ?? "", contentHash: fingerprint, citations: [])
                }
                result.append(retained)
            }
        }

        return result
    }

    private static func firstMatch(
        of generated: SummaryEntry,
        in existing: [SummaryEntry],
        excluding consumed: Set<UUID>
    ) -> SummaryEntry? {
        let genKey = SummaryEntry.normalizedFactKey(generated.factKey)
        if let genKey {
            if let match = existing.first(where: {
                !consumed.contains($0.id)
                    && $0.category == generated.category
                    && SummaryEntry.normalizedFactKey($0.factKey) == genKey
                    && ($0.isDeleted || !HealthFactMatching.conflicts($0, generated))
            }) {
                return match
            }
        }

        let genTitle = generated.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !genTitle.isEmpty else { return nil }
        if let match = existing.first(where: {
            !consumed.contains($0.id)
                && $0.category == generated.category
                && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == genTitle
                && ($0.isDeleted || !HealthFactMatching.conflicts($0, generated))
        }) { return match }
        guard let excerpt = generated.evidence?.excerpt, !excerpt.isEmpty else { return nil }
        let candidates = existing.filter {
            !consumed.contains($0.id) && $0.category == generated.category && $0.sourceSessionID == generated.sourceSessionID
                && $0.evidence?.excerpt == excerpt && !HealthFactMatching.conflicts($0, generated)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func reconcile(generated: SummaryEntry, existing: SummaryEntry) -> SummaryEntry {
        var merged = generated
        merged.id = existing.id
        merged.createdAt = existing.createdAt
        if merged.evidence == nil { merged.evidence = ClinicalEvidence() }
        merged.evidence?.factIdentity = existing.evidence?.factIdentity
        merged.evidence?.combinationExcluded = existing.evidence?.combinationExcluded
        merged.evidence?.combinationPrimary = existing.evidence?.combinationPrimary
        if let identity = existing.evidence?.instructionIdentity {
            if merged.evidence == nil { merged.evidence = ClinicalEvidence() }
            merged.evidence?.instructionIdentity = identity
            merged.evidence?.combinationExcluded = existing.evidence?.combinationExcluded
        }
        merged.factKey = generated.factKey ?? existing.factKey

        if existing.isDeleted {
            merged.isDeleted = true
            merged.origin = existing.origin == .userAdded ? .userAdded : .userEdited
            merged.clinicalStatus = existing.clinicalStatus
            merged.title = existing.title.isEmpty ? generated.title : existing.title
            merged.details = existing.details
            merged.fields = existing.fields.isEmpty ? generated.fields : existing.fields
            merged.updatedAt = existing.updatedAt
            return merged
        }

        if existing.origin == .userEdited || existing.origin == .userAdded {
            merged.evidence = existing.evidence
            merged.title = existing.title
            merged.details = existing.details
            merged.fields = existing.fields
            merged.clinicalStatus = existing.clinicalStatus
            merged.origin = existing.origin
            merged.relevantDate = existing.relevantDate ?? generated.relevantDate
            merged.dateNeedsReview = existing.dateNeedsReview
            merged.needsReview = existing.needsReview
            merged.reviewReason = existing.reviewReason
            merged.updatedAt = existing.updatedAt
            if merged.sourceExcerpt == nil {
                merged.sourceExcerpt = existing.sourceExcerpt
            }
            return merged
        }

        merged.clinicalStatus = generated.clinicalStatus
        if SummaryVerification.contentHash(merged) == SummaryVerification.contentHash(existing) {
            merged.updatedAt = existing.updatedAt
        }
        return merged
    }
}
