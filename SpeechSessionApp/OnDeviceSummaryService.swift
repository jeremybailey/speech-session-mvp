import Foundation
import FoundationModels
import SpeechSessionPersistence

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

    @Generable
    struct OverviewSentence: Encodable {
        var text: String
        var factIDs: [String]
    }

    @Generable
    struct OverviewNarrative: Encodable {
        var sentences: [OverviewSentence]
    }

    @Generable
    struct OverviewProse: Encodable {
        var text: String
    }

    @Generable
    struct OverviewSupport: Encodable {
        var supported: Bool
        var reason: String
    }

    // MARK: - Structured Output

    @Generable
    struct VisitFactRow {
        @Guide(description: "Short stable title (e.g. Migraine, Metformin).")
        var title: String

        @Guide(description: "Severity, course, dose, or other detail. Empty if the title is enough.")
        var details: String?

        @Guide(description: "current if ongoing; past if resolved, stopped, completed, or historical.")
        var clinicalStatus: String?

        @Guide(description: "Stable lowercase concept slug across visits. Use the same slug for equivalent wording, preserving side, negation, dose, and clinical meaning. Headache and migraine are distinct.")
        var factKey: String?

        @Guide(description: "Body system for chief complaints only (e.g. Neurological). Empty otherwise.")
        var bodySystem: String?
        @Guide(description: "Short verbatim source passage supporting this fact; include qualifiers and negation.")
        var sourceExcerpt: String?
        @Guide(description: "Explicit event date YYYY-MM-DD, YYYY-MM or YYYY. Omit if not stated.")
        var eventDate: String?
        @Guide(description: "Names of health topics explicitly associated with this fact. Empty if not stated.")
        var topicNames: [String]
        var practitioner: String?
        var assessmentMethod: String?
        var dose: String?
        var frequency: String?
        var reasonStarted: String?
        var reasonStopped: String?
        @Guide(description: "homecare, follow_up, treatment_received, self_directed or uncertain. Omit for non-actions.")
        var actionKind: String?
        @Guide(description: "Care plans only: one complete action sentence from the source. Do not repeat it in details or another row.")
        var instruction: String?
        var additionalDirections: String?
        var goal: String?
        var schedule: String?
        var reviewTiming: String?
        @Guide(description: "True for ongoing/repeated instructions, false for an explicit one-time task; omit if unknown.")
        var isRecurring: Bool?
        @Guide(description: "True only when the source explicitly supports current/past status.")
        var statusExplicit: Bool
        var reviewReason: String?
        @Guide(description: "Contacts only: organization, role, phone, email and postal address in separate fields, from the same source block. Never put field labels inside values.")
        var contact: ContactRow?
    }

    @Generable
    struct ContactRow {
        var name: String
        var organization: String?
        var role: String?
        var phone: String?
        var email: String?
        var address: String?
    }

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

        @Guide(description: "Lowercase hyphenated slug, usually the drug name (e.g. metformin).")
        var factKey: String?

        @Guide(description: "current if still taking; past if stopped, completed, or historical.")
        var clinicalStatus: String?
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

        @Guide(description: """
        One contact per line from printed headers. Include name, organization, role, phone, email, and address only when explicitly tied \
        to that same contact block. Never merge a name from one part of the document with contact text from another.
        """)
        var practitionerContacts: String?

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

        @Guide(description: "One fact per distinct complaint. Include clinicalStatus (current/past) and factKey.")
        var chiefComplaint: [VisitFactRow]

        @Guide(description: "One fact per distinct symptom, not separate title and expanded-description objects. Use consistent titles for equivalent wording; preserve location, side and negation. Include clinicalStatus (current/past) and factKey.")
        var symptoms: [VisitFactRow]

        @Guide(description: "Examination findings, diagnoses, impressions—NOT the treatment plan itself.")
        var findings: [VisitFactRow]

        @Guide(description: "Medications named, doses, changes, adherence. Include clinicalStatus and factKey.")
        var medications: [VisitFactRow]

        @Guide(description: """
        REQUIRED bucket for clinician-directed ACTIONS: referrals, procedures, imaging/therapy orders, \
        medication initiation/taper/adjustment discussed as today's plan, device instructions, PT/OT/home exercise, \
        diet/lifestyle advice from clinician, patient education—anything 'we should / start / continue / refer / order'.
        """ )
        var treatmentPlan: [VisitFactRow]

        @Guide(description: """
        One contact per item. Include a person or clinic/org name plus role, phone, email, and address only when explicitly tied to that \
        same source block. Never associate a provider mentioned in dialogue with Rx/pharmacy address from a different block or entry. \
        Omit first-name-only speech and missing details.
        """)
        var practitionerContacts: [VisitFactRow]

        @Guide(description: "Vaccination history mentioned in this visit.")
        var vaccinations: [VisitFactRow]

        @Guide(description: "Allergies or adverse reactions mentioned.")
        var allergies: [VisitFactRow]

        @Guide(description: "Tests, labs, or imaging discussed (ordered/pending/results).")
        var testsAndLabs: [VisitFactRow]

        @Guide(description: "ONLY scheduling logistics: when to return, call backs, booking next visit—not the full therapeutic plan.")
        var followUp: [VisitFactRow]

        @Guide(description: """
        Important information that does not fit any other field. Leave empty if everything maps cleanly elsewhere; \
        do not duplicate other sections.
        """)
        var otherNotes: [VisitFactRow]
        @Guide(description: "Stated mental health, daily-life circumstances, diet, lifestyle and personal context.")
        var biopsychosocialContext: [VisitFactRow]
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
        ONE short plain-English paragraph (about 2–4 sentences) that sets clinical context for this patient— \
        main ongoing themes and care situation. Not bullets, not category headings, not a first-person spoken script. Facts only.
        """)
        var overview: String?
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

    func generateFields(transcript: String, contentKind: SummaryContentKind) async throws -> VisitSummaryFields {
        let instructions = SummaryPromptAssembly.onDeviceSessionInstructions(contentKind: contentKind)
        let session = LanguageModelSession(instructions: instructions)
        let lead = SummaryPromptAssembly.onDeviceUserPromptLead(contentKind: contentKind)
        let prompt = lead + transcript

        let response = try await session.respond(to: prompt, generating: StructuredVisitSummary.self)
        return Self.visitSummaryFields(from: response.content)
    }

    func generate(transcript: String, contentKind: SummaryContentKind) async throws -> (title: String, summary: String) {
        let defaultTitle: String
        switch contentKind {
        case .visitEncounter:
            defaultTitle = "Visit"
        case .personalJournal:
            defaultTitle = "Journal"
        case .carePlanEducation, .medicationReference, .mixedOther:
            defaultTitle = "Health document"
        }

        let fields = try await generateFields(transcript: transcript, contentKind: contentKind)
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
        You are a medical scribe writing a short longitudinal OVERVIEW. \
        Extract only clinically relevant information explicitly stated in the provided entry data. \
        Do not infer, assume, or invent any clinical details. \
        Return only an overview paragraph (2–4 sentences) about the patient's care themes—not a bullet digest and not first-person spoken script.
        """)

        let response = try await session.respond(to: prompt, generating: GlobalSummaryOutput.self)
        return GlobalSummaryPayload(overview: response.content.overview?.trimmedNilIfEmpty)
    }

    private static func visitSummaryFields(from output: StructuredVisitSummary) -> VisitSummaryFields {
        var fields = VisitSummaryFields(
            title: output.title,
            legacyMarkdownSummary: nil
        )
        fields.factsByCategory = [
            .chiefComplaint: facts(from: output.chiefComplaint, chiefComplaint: true),
            .symptoms: facts(from: output.symptoms),
            .findings: facts(from: output.findings),
            .medications: facts(from: output.medications),
            .carePlan: facts(from: output.treatmentPlan),
            .practitionerContact: facts(from: output.practitionerContacts),
            .vaccinations: facts(from: output.vaccinations),
            .allergies: facts(from: output.allergies),
            .testsAndLabs: facts(from: output.testsAndLabs),
            .followUp: facts(from: output.followUp),
            .otherNotes: facts(from: output.otherNotes),
            .biopsychosocialContext: facts(from: output.biopsychosocialContext),
        ]
        return fields
    }

    private static func facts(from rows: [VisitFactRow], chiefComplaint: Bool = false) -> [VisitSummaryFact] {
        rows.compactMap { row in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let details = row.details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var evidence = ClinicalEvidence()
            if let c = row.contact {
                evidence.contactFields = [("Name", Optional(c.name)), ("Organization", c.organization),
                    ("Role or specialty", c.role), ("Phone", c.phone), ("Email", c.email), ("Address", c.address)].compactMap { label, value in
                    guard let value, !value.isEmpty else { return nil }
                    return SummaryEntryField(label: label, value: value)
                }
            }
            evidence.excerpt = row.sourceExcerpt; evidence.eventDate = row.eventDate
            evidence.topicNames = row.topicNames; evidence.bodySystem = row.bodySystem
            evidence.practitioner = row.practitioner; evidence.assessmentMethod = row.assessmentMethod
            evidence.dose = row.dose; evidence.frequency = row.frequency
            evidence.reasonStarted = row.reasonStarted; evidence.reasonStopped = row.reasonStopped
            if row.instruction != nil {
                evidence.careInstruction = CareInstruction(instruction: row.instruction, directions: row.additionalDirections,
                    goal: row.goal, schedule: row.schedule, reviewTiming: row.reviewTiming, isRecurring: row.isRecurring)
            }
            evidence.actionKind = row.actionKind; evidence.statusExplicit = row.statusExplicit
            evidence.reviewReason = row.reviewReason
            return VisitSummaryFact(
                title: title,
                details: details,
                bodySystem: chiefComplaint ? BodySystem.parse(row.bodySystem) : nil,
                clinicalStatus: SummaryEntryClinicalStatus.parse(row.clinicalStatus),
                factKey: SummaryEntry.normalizedFactKey(row.factKey) ?? SummaryEntry.normalizedFactKey(title),
                evidence: evidence
            )
        }
    }

    private static func visitSummaryFields(from med: MedicationRefStructuredSummary) -> VisitSummaryFields {
        let medFacts: [VisitSummaryFact] = med.medicationItems.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var parts: [String] = []
            if let s = row.strength?.trimmedNilIfEmpty { parts.append(s) }
            if let s = row.frequency?.trimmedNilIfEmpty { parts.append(s) }
            if let s = row.route?.trimmedNilIfEmpty { parts.append(s) }
            if let s = row.duration?.trimmedNilIfEmpty { parts.append(s) }
            if let s = row.instructions?.trimmedNilIfEmpty { parts.append(s) }
            if let s = row.classOrCategoryIfStated?.trimmedNilIfEmpty {
                parts.append("Class (per source): \(s)")
            }
            return VisitSummaryFact(
                title: name,
                details: parts.joined(separator: "; "),
                bodySystem: nil,
                clinicalStatus: SummaryEntryClinicalStatus.parse(row.clinicalStatus),
                factKey: SummaryEntry.normalizedFactKey(row.factKey) ?? SummaryEntry.normalizedFactKey(name)
            )
        }

        var fields = VisitSummaryFields(
            title: med.title,
            legacyMarkdownSummary: nil,
            chiefComplaint: med.chiefComplaint,
            symptoms: med.symptoms,
            findings: med.findings,
            medications: nil,
            treatmentPlan: med.treatmentPlan,
            practitionerContacts: med.practitionerContacts,
            vaccinations: med.vaccinations,
            allergies: med.allergies,
            testsAndLabs: med.testsAndLabs,
            followUp: med.followUp,
            otherNotes: med.otherNotes
        )
        if !medFacts.isEmpty {
            fields.factsByCategory[.medications] = medFacts
        }
        return fields
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
