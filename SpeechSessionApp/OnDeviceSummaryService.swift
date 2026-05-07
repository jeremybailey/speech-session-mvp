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
    }

    // MARK: - Generation

    func generate(transcript: String) async throws -> (title: String, summary: String) {
        let session = LanguageModelSession(instructions: """
        You are a medical scribe reviewing an appointment transcript. Extract only clinically relevant information \
        explicitly stated—ignore greetings, small talk, and scheduling-only chatter unless it belongs under followUp. \
        Do not infer, assume, or invent clinical details.

        Populate ONLY the structured fields provided; leave a field absent/empty instead of hallucinating filler.

        \(VisitSummaryPromptGuidance.categoryRoutingRules)
        """)

        let prompt = "Summarize this medical appointment transcript:\n\n\(transcript)"
        let response = try await session.respond(to: prompt, generating: StructuredVisitSummary.self)
        let output = response.content

        let fields = VisitSummaryFields(
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
            followUp: output.followUp
        )

        let defaultTitle = "Visit"
        guard let (titleText, markdown) = fields.resolved(defaultTitle: defaultTitle), !markdown.isEmpty else {
            throw OnDeviceVisitSummaryEmptyError.noStructuredContent
        }

        return (title: titleText, summary: markdown)
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
            biopsychosocialContext: output.biopsychosocialContext?.trimmedNilIfEmpty
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
