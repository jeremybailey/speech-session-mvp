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
        Available sections: Chief Complaint, Symptoms, Diagnoses / Conditions, Medications, \
        Treatment Plan, Vaccinations, Allergies, Tests & Labs Ordered, Follow-up.
        """)
        var summary: String
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
}
