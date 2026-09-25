import Foundation

struct SessionsEnvelope: Codable, Equatable {
    var verifiedPairDecisions: [String: Bool] = [:]
    var version: Int
    var sessions: [Session]
    var folders: [SessionFolder]

    var topics: [HealthTopic] = []
    var careTeam: [CareTeamMember] = []
    var preferences: [HealthFactPreference] = []
    var profile: PatientProfile = .init()

    static let currentVersion = 4

    enum CodingKeys: String, CodingKey {
        case version, sessions, folders, topics, careTeam, preferences, profile, verifiedPairDecisions
    }

    init(version: Int = Self.currentVersion, sessions: [Session], folders: [SessionFolder] = []) {
        self.version = version
        self.sessions = sessions
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verifiedPairDecisions = try c.decodeIfPresent([String: Bool].self, forKey: .verifiedPairDecisions) ?? [:]
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try c.decode([Session].self, forKey: .sessions)
        folders = try c.decodeIfPresent([SessionFolder].self, forKey: .folders) ?? []
        topics = try c.decodeIfPresent([HealthTopic].self, forKey: .topics) ?? []
        careTeam = try c.decodeIfPresent([CareTeamMember].self, forKey: .careTeam) ?? []
        preferences = try c.decodeIfPresent([HealthFactPreference].self, forKey: .preferences) ?? []
        profile = try c.decodeIfPresent(PatientProfile.self, forKey: .profile) ?? .init()
    }
}
