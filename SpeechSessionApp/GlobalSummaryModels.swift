import Foundation

/// The model sometimes returns a plain string, sometimes a JSON array of strings.
/// This struct handles both by normalising arrays into "- item" bullet strings.
struct GlobalSummaryPayload: Codable {
    var chiefComplaint: String?
    var symptoms: String?
    var diagnoses: String?
    var medications: String?
    var carePlans: String?
    var vaccinations: String?
    var allergies: String?
    var testsAndLabs: String?
    var followUp: String?
    var biopsychosocialContext: String?
    /// Important details that do not fit other longitudinal fields; avoid duplicating structured sections.
    var otherNotes: String?

    enum CodingKeys: String, CodingKey {
        case chiefComplaint
        case symptoms, diagnoses, medications, carePlans, vaccinations
        case allergies, testsAndLabs, followUp, biopsychosocialContext, otherNotes
    }

    init(
        chiefComplaint: String? = nil,
        symptoms: String? = nil,
        diagnoses: String? = nil,
        medications: String? = nil,
        carePlans: String? = nil,
        vaccinations: String? = nil,
        allergies: String? = nil,
        testsAndLabs: String? = nil,
        followUp: String? = nil,
        biopsychosocialContext: String? = nil,
        otherNotes: String? = nil
    ) {
        self.chiefComplaint = chiefComplaint
        self.symptoms = symptoms
        self.diagnoses = diagnoses
        self.medications = medications
        self.carePlans = carePlans
        self.vaccinations = vaccinations
        self.allergies = allergies
        self.testsAndLabs = testsAndLabs
        self.followUp = followUp
        self.biopsychosocialContext = biopsychosocialContext
        self.otherNotes = otherNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chiefComplaint = c.decodeFlexible(.chiefComplaint)
        symptoms = c.decodeFlexible(.symptoms)
        diagnoses = c.decodeFlexible(.diagnoses)
        medications = c.decodeFlexible(.medications)
        carePlans = c.decodeFlexible(.carePlans)
        vaccinations = c.decodeFlexible(.vaccinations)
        allergies = c.decodeFlexible(.allergies)
        testsAndLabs = c.decodeFlexible(.testsAndLabs)
        followUp = c.decodeFlexible(.followUp)
        biopsychosocialContext = c.decodeFlexible(.biopsychosocialContext)
        otherNotes = c.decodeFlexible(.otherNotes)
    }

    /// Category rows that have content — shared by global and folder-scoped summaries.
    var nonemptyDisplaySections: [(title: String, content: String)] {
        let entries: [(title: String, content: String?)] = [
            ("Chief Complaint", chiefComplaint),
            ("Symptoms", symptoms),
            ("Findings", diagnoses),
            ("Medications", medications),
            ("Care Plans", carePlans),
            ("Vaccinations", vaccinations),
            ("Allergies", allergies),
            ("Tests & Labs", testsAndLabs),
            ("Follow-up", followUp),
            ("Biopsychosocial Context", biopsychosocialContext),
            ("Other Notes", otherNotes),
        ]
        return entries.compactMap { title, content in
            guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (title, content)
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes a key that may arrive as a `String` or `[String]`.
    func decodeFlexible(_ key: Key) -> String? {
        if let str = try? decode(String.self, forKey: key), !str.isEmpty { return str }
        if let arr = try? decode([String].self, forKey: key), !arr.isEmpty {
            return arr.map { "- \($0)" }.joined(separator: "\n")
        }
        return nil
    }
}
