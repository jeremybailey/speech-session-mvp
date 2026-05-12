import Foundation

struct SessionsEnvelope: Codable, Equatable {
    var version: Int
    var sessions: [Session]
    var folders: [SessionFolder]

    static let currentVersion = 2

    enum CodingKeys: String, CodingKey {
        case version, sessions, folders
    }

    init(version: Int = Self.currentVersion, sessions: [Session], folders: [SessionFolder] = []) {
        self.version = version
        self.sessions = sessions
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try c.decode([Session].self, forKey: .sessions)
        folders = try c.decodeIfPresent([SessionFolder].self, forKey: .folders) ?? []
    }
}
