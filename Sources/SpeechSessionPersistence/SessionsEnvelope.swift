import Foundation

struct SessionsEnvelope: Codable, Equatable {
    var version: Int
    var sessions: [Session]

    static let currentVersion = 1

    init(version: Int = Self.currentVersion, sessions: [Session]) {
        self.version = version
        self.sessions = sessions
    }
}
