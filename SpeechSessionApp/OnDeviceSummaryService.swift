import Foundation
import FoundationModels

/// On-device medical summary generation via Apple's Foundation Models framework.
/// Requires iOS 18.1+ with Apple Intelligence enabled (iPhone 15 Pro+, iPhone 16, M1 iPad+).
@available(iOS 26.0, *)
struct OnDeviceSummaryService {

    // MARK: - Availability

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailabilityReason: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device doesn't support Apple Intelligence (requires iPhone 15 Pro+, iPhone 16, or M1 iPad)."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is not enabled. Go to Settings → Apple Intelligence & Siri to turn it on."
            case .modelNotReady:
                return "Apple Intelligence is not ready yet on this device. Try again in a moment, or use OpenAI summaries in Settings."
            @unknown default:
                return "Apple Intelligence is not available on this device."
            }
        }
    }

    // MARK: - Structured Output

    @Generable
    struct MedicationItemRow {
        @Guide(description: "Drug name exactly as stated in the source.")
        var name: String

        @Guide(description: "Strength or dose (e.g. 50 mg). Verbatim; do not change numbers.")
        var strength: String?

        @Guide(description: "Dosing schedule or frequency if stated.")
        var frequency: String?

        @Guide(description: "Route (oral, topical, etc.) if stated.")
        var route: String?

        @Guide(description: "Duration or course length if stated.")
        var duration: String?

        @Guide(description: "Patient directions, changes, or pharmacy notes tied to this drug.")
        var instructions: String?

        @Guide(description: """
        Pharmacologic class or category ONLY if the source explicitly ties it to THIS medication. \
        Leave empty if absent or uncertain—never infer from the drug name alone.
        """)
        var classOrCategoryIfStated: String?
    }

    /// Structured summary for medication lists and prescription printouts (on-device).
    @Generable
    struct MedicationRefStructuredSummary {
        @Guide(description: "Short title, 3–6 words (e.g. Home medication list, Discharge prescriptions).")
        var title: String

        @Guide(description: "One entry per drug or prescription line from the source.")
        var medicationItems: [MedicationItemRow]

        @Guide(description: "Allergies or adverse reactions if listed.")
        var allergies: String?

        @Guide(description: "Narrative prescriber/pharmacist directions, tapers, or monitoring beyond per-line sigs.")
        var treatmentPlan: String?

        @Guide(description: "Tests, labs, or monitoring explicitly tied to medications in the source.")
        var testsAndLabs: String?

        @Guide(description: "Vaccinations mentioned alongside the medication context.")
        var vaccinations: String?

        @Guide(description: "Refill, return visit, or callback logistics if explicitly stated.")
        var followUp: String?

        @Guide(description: "Indication, chief concern, or symptom context only when clearly stated in the source.")
        var chiefComplaint: String?

        @Guide(description: "Symptoms or side effects only when explicitly tied to the source text.")
        var symptoms: String?

        @Guide(description: "Diagnoses or indications only when explicitly stated.")
        var findings: String?

        @Guide(description: """
        Important details that do not fit other fields. Do not repeat medication rows or duplicate structured content.
        """)
        var otherNotes: String?
    }

    @Generable
    struct StructuredVisitSummary {
        @Guide(description: "Short appointment title, 3–6 words (e.g. Back pain follow-up, Annual physical exam).")
        var title: String

        @Guide(description: "Chief complaint / reason for visit, if stated.")
        var chiefComplaint: String?

        @Guide(description: "Current symptoms and concerns explicitly mentioned.")
        var symptoms: String?

        @Guide(description: "Examination findings, diagnoses, impressions—NOT the treatment plan itself.")
        var findings: String?

        @Guide(description: "Medications named, doses, changes, adherence. If a new drug is STARTED today, mention it here AND describe the prescribing intent again under Treatment Plan.")
        var medications: String?

        @Guide(description: """
        REQUIRED bucket for clinician-directed ACTIONS: referrals, procedures, imaging/therapy orders, \
        medication initiation/taper/adjustment discussed as today's plan, device instructions, PT/OT/home exercise, \
        diet/lifestyle advice from clinician, patient education—anything 'we should / start / continue / refer / order'.
        """ )
        var treatmentPlan: String?

        @Guide(description: "Vaccination history mentioned in this visit.")
        var vaccinations: String?

        @Guide(description: "Allergies or adverse reactions mentioned.")
        var allergies: String?

        @Guide(description: "Tests, labs, or imaging discussed (ordered/pending/results).")
        var testsAndLabs: String?

        @Guide(description: "ONLY scheduling logistics: when to return, call backs, booking next visit—not the full therapeutic plan.")
        var followUp: String?

        @Guide(description: """
        Important information that does not fit any other field. Leave empty if everything maps cleanly elsewhere; \
        do not duplicate other sections.
        """)
        var otherNotes: String?
    }

    @Generable
    struct TranscriptClassification {
        @Guide(description: """
        Exactly one label: visit_encounter, care_plan_education, medication_reference, personal_journal, or mixed_other. \
        visit_encounter = dialogue or visit note. care_plan_education = handouts, care plans, education. \
        medication_reference = mostly medication lists. personal_journal = diary-style first-person journaling. \
        mixed_other = unclear or blended.
        """)
        var contentKind: String
    }

    @Generable
    struct GlobalSummaryOutput {
        @Guide(description: """
        Concise longitudinal overview of the main problems, reasons for care, and presenting concerns across visits—the \
        high-level 'why' tying entries together—not a verbatim label from each visit unless that is the explicit content.
        """)
        var chiefComplaint: String?

        @Guide(description: "Current and historical symptoms explicitly mentioned across all visits.")
        var symptoms: String?

        @Guide(description: "Findings from diagnosed conditions, confirmed medical history, and clinically relevant observations.")
        var diagnoses: String?

        @Guide(description: "Current medications and explicitly stated medication changes, prioritizing recent entry data.")
        var medications: String?

        @Guide(description: """
        Consolidate ALL ongoing clinician-directed treatment and planning across visits: medication changes/initiation, \
        referrals, surgeries/procedures discussed, therapies, devices, clinical lifestyle/diet instructions, education, \
        care coordination. Do NOT park clinical plans only in biopsychosocialContext or followUp.
        """)
        var carePlans: String?

        @Guide(description: "Vaccination history explicitly mentioned.")
        var vaccinations: String?

        @Guide(description: "Known allergies and adverse reactions explicitly mentioned.")
        var allergies: String?

        @Guide(description: "Ordered, pending, or completed tests and labs.")
        var testsAndLabs: String?

        @Guide(description: "ONLY scheduling/return-visit logistics across entries (when to come back, call-backs). Not the full treatment plan.")
        var followUp: String?

        @Guide(description: """
        ONLY non-clinical psychosocial / life context (work stress, bereavement, housing, social support, financial strain, \
        mental health themes without a specific clinical order). Never place referrals, medication plans, procedures, or \
        clinician instructions here—those belong in carePlans, medications, or testsAndLabs.
        """)
        var biopsychosocialContext: String?

        @Guide(description: "Important longitudinal details with no natural home in other fields; omit if empty. No duplication.")
        var otherNotes: String?
    }

    // MARK: - Classification (on-device)

    func classifyTranscript(_ transcript: String) async throws -> SummaryContentKind {
        let snippet = transcript.count > 14_000
            ? String(transcript.prefix(14_000)) + "\n\n[… truncated …]"
            : transcript

        let session = LanguageModelSession(instructions: """
        You classify health-related source text before summarization. \
        Reply using ONLY the structured field provided with one of these exact contentKind strings: \
        visit_encounter, care_plan_education, medication_reference, personal_journal, mixed_other. \
        visit_encounter: dialogue, clinical conversation, or visit note. \
        care_plan_education: care plans, discharge/education handouts, disease information. \
        medication_reference: primarily medication or prescription lists. \
        personal_journal: first-person health journaling or diary—not a clinical note. \
        mixed_other: blended or uncertain. Pick exactly one best label.
        """)

        let response = try await session.respond(
            to: "Classify this health-related text:\n\n\(snippet)",
            generating: TranscriptClassification.self
        )
        return SummaryContentKind(rawUnstable: response.content.contentKind)
    }

    // MARK: - Generation (single entry)

    func generate(transcript: String, contentKind: SummaryContentKind) async throws -> (title: String, summary: String) {
        let instructions = SummaryPromptAssembly.onDeviceSessionInstructions(contentKind: contentKind)
        let session = LanguageModelSession(instructions: instructions)
        let lead = SummaryPromptAssembly.onDeviceUserPromptLead(contentKind: contentKind)
        let prompt = lead + transcript

        let defaultTitle: String
        switch contentKind {
        case .visitEncounter:
            defaultTitle = "Visit"
        case .personalJournal:
            defaultTitle = "Journal"
        case .carePlanEducation, .medicationReference, .mixedOther:
            defaultTitle = "Health document"
        }

        let fields: VisitSummaryFields
        switch contentKind {
        case .medicationReference:
            let response = try await session.respond(to: prompt, generating: MedicationRefStructuredSummary.self)
            fields = Self.visitSummaryFields(from: response.content)
        default:
            let response = try await session.respond(to: prompt, generating: StructuredVisitSummary.self)
            let output = response.content
            fields = VisitSummaryFields(
                title: output.title,
                legacyMarkdownSummary: nil,
                chiefComplaint: output.chiefComplaint,
                symptoms: output.symptoms,
                findings: output.findings,
                medications: output.medications,
                treatmentPlan: output.treatmentPlan,
                vaccinations: output.vaccinations,
                allergies: output.allergies,
                testsAndLabs: output.testsAndLabs,
                followUp: output.followUp,
                otherNotes: output.otherNotes
            )
        }

        guard let (titleText, markdown) = fields.resolved(defaultTitle: defaultTitle), !markdown.isEmpty else {
            throw OnDeviceVisitSummaryEmptyError.noStructuredContent
        }

        return (title: titleText, summary: markdown)
    }

    /// Convenience — assumes a visit-style encounter.
    func generate(transcript: String) async throws -> (title: String, summary: String) {
        try await generate(transcript: transcript, contentKind: .visitEncounter)
    }

    func generateGlobalSummary(prompt: String) async throws -> GlobalSummaryPayload {
        let session = LanguageModelSession(instructions: """
        You are a medical scribe synthesizing a longitudinal health profile. \
        Extract only clinically relevant information explicitly stated in the provided entry data. \
        Do not infer, assume, or invent any clinical details. \
        Omit fields that have no relevant content. \
        Be concise and format multi-item fields as markdown bullet lists.

        Longitudinal CATEGORY RULES: \
        Put actionable clinician-directed plans (medication changes/referrals/therapies/procedures/education/coordination) in carePlans—not in biopsychosocialContext or followUp alone. \
        followUp is for scheduling/return logistics across visits. \
        biopsychosocialContext is ONLY psychosocial or life-context without a clinical order.
        """)

        let response = try await session.respond(to: prompt, generating: GlobalSummaryOutput.self)
        let output = response.content
        return GlobalSummaryPayload(
            chiefComplaint: output.chiefComplaint?.trimmedNilIfEmpty,
            symptoms: output.symptoms?.trimmedNilIfEmpty,
            diagnoses: output.diagnoses?.trimmedNilIfEmpty,
            medications: output.medications?.trimmedNilIfEmpty,
            carePlans: output.carePlans?.trimmedNilIfEmpty,
            vaccinations: output.vaccinations?.trimmedNilIfEmpty,
            allergies: output.allergies?.trimmedNilIfEmpty,
            testsAndLabs: output.testsAndLabs?.trimmedNilIfEmpty,
            followUp: output.followUp?.trimmedNilIfEmpty,
            biopsychosocialContext: output.biopsychosocialContext?.trimmedNilIfEmpty,
            otherNotes: output.otherNotes?.trimmedNilIfEmpty
        )
    }

    private static func visitSummaryFields(from med: MedicationRefStructuredSummary) -> VisitSummaryFields {
        let medBody: String
        if med.medicationItems.isEmpty {
            medBody = ""
        } else {
            medBody = med.medicationItems.map { row in
                var parts: [String] = []
                if let s = row.strength?.trimmedNilIfEmpty { parts.append(s) }
                if let s = row.frequency?.trimmedNilIfEmpty { parts.append(s) }
                if let s = row.route?.trimmedNilIfEmpty { parts.append(s) }
                if let s = row.duration?.trimmedNilIfEmpty { parts.append(s) }
                if let s = row.instructions?.trimmedNilIfEmpty { parts.append(s) }
                if let s = row.classOrCategoryIfStated?.trimmedNilIfEmpty {
                    parts.append("Class (per source): \(s)")
                }
                let tail = parts.joined(separator: "; ")
                let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty { return "- \(name)" }
                return "- \(name) — \(tail)"
            }.joined(separator: "\n")
        }

        return VisitSummaryFields(
            title: med.title,
            legacyMarkdownSummary: nil,
            chiefComplaint: med.chiefComplaint,
            symptoms: med.symptoms,
            findings: med.findings,
            medications: medBody.isEmpty ? nil : medBody,
            treatmentPlan: med.treatmentPlan,
            vaccinations: med.vaccinations,
            allergies: med.allergies,
            testsAndLabs: med.testsAndLabs,
            followUp: med.followUp,
            otherNotes: med.otherNotes
        )
    }
}

@available(iOS 26.0, *)
private enum OnDeviceVisitSummaryEmptyError: LocalizedError {
    case noStructuredContent

    var errorDescription: String? {
        switch self {
        case .noStructuredContent:
            return "The model returned an empty summary. Try again."
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
