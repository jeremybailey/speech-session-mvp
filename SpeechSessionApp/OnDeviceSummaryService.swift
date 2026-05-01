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
            @unknown default:
                return "Apple Intelligence is not available on this device."
            }
        }
    }

    // MARK: - Structured Output

    @Generable
    struct SummaryOutput {
        @Guide(description: "A short appointment title, 3–6 words, e.g. 'Back pain follow-up' or 'Annual physical exam'")
        var title: String

        @Guide(description: """
        A structured markdown medical summary using ## section headers. \
        Only include sections where information was actually mentioned in the transcript. \
        Available sections: Chief Complaint, Symptoms, Findings, Medications, \
        Treatment Plan, Vaccinations, Allergies, Tests & Labs Ordered, Follow-up.
        """)
        var summary: String
    }

    @Generable
    struct GlobalSummaryOutput {
        @Guide(description: "Current and historical symptoms explicitly mentioned across all visits.")
        var symptoms: String?

        @Guide(description: "Findings from diagnosed conditions, confirmed medical history, and clinically relevant observations.")
        var diagnoses: String?

        @Guide(description: "Current medications and explicitly stated medication changes, prioritizing recent session data.")
        var medications: String?

        @Guide(description: "Ongoing treatment and care plans mentioned across visits.")
        var carePlans: String?

        @Guide(description: "Vaccination history explicitly mentioned.")
        var vaccinations: String?

        @Guide(description: "Known allergies and adverse reactions explicitly mentioned.")
        var allergies: String?

        @Guide(description: "Ordered, pending, or completed tests and labs.")
        var testsAndLabs: String?

        @Guide(description: "Upcoming or recommended follow-up actions.")
        var followUp: String?

        @Guide(description: "Psychosocial and life-context factors mentioned across sessions.")
        var biopsychosocialContext: String?
    }

    // MARK: - Generation

    func generate(transcript: String) async throws -> (title: String, summary: String) {
        let session = LanguageModelSession(instructions: """
        You are a medical scribe reviewing an appointment recording transcript. \
        Extract only clinically relevant information explicitly stated in the transcript. \
        Ignore all greetings, small talk, scheduling chatter, and personal conversation. \
        Do not infer, assume, or invent any clinical details not present in the transcript. \
        If a summary section has no relevant content, omit it entirely rather than filling it with guesses. \
        Be concise and precise. Use plain medical terminology.
        """)

        let prompt = "Summarize this medical appointment transcript:\n\n\(transcript)"
        let response = try await session.respond(to: prompt, generating: SummaryOutput.self)

        return (
            title: response.content.title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func generateGlobalSummary(prompt: String) async throws -> GlobalSummaryPayload {
        let session = LanguageModelSession(instructions: """
        You are a medical scribe synthesizing a longitudinal health profile. \
        Extract only clinically relevant information explicitly stated in the provided session data. \
        Do not infer, assume, or invent any clinical details. \
        Omit fields that have no relevant content. \
        Be concise and format multi-item fields as markdown bullet lists.
        """)

        let response = try await session.respond(to: prompt, generating: GlobalSummaryOutput.self)
        let output = response.content
        return GlobalSummaryPayload(
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

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
