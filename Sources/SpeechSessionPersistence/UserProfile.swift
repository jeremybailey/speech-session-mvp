import Foundation
import CryptoKit

/// Account identity is separate from the patient's clinical record and transfer archives.
public struct UserProfile: Codable, Equatable, Sendable {
    public var name: String
    public var photoData: Data?
    public var nameEdited: Bool

    public init(name: String = "", photoData: Data? = nil, nameEdited: Bool = false) {
        self.name = name; self.photoData = photoData; self.nameEdited = nameEdited
    }
}

public enum UserProfileError: Error { case invalidProfile }

public actor UserProfileStore {
    public static let maximumPhotoBytes = 512_000
    public static let maximumNameLength = 200
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func appDefault() throws -> UserProfileStore {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SessionStoreError.missingApplicationSupport
        }
        return UserProfileStore(directory: support.appendingPathComponent("CollectiveCareProfiles", isDirectory: true))
    }

    private func file(accountID: String?) -> URL {
        let identity = accountID.map { "account:" + $0 } ?? "device:local"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    public func load(accountID: String?) throws -> UserProfile {
        let url = file(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return UserProfile() }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 800_000 else { throw UserProfileError.invalidProfile }
        let profile = try JSONDecoder().decode(UserProfile.self, from: data)
        try validate(profile)
        return profile
    }

    /// Seed only a missing name. An explicitly edited (even empty) name always wins.
    public func seedName(_ name: String, accountID: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maximumNameLength else { return }
        var profile = try load(accountID: accountID)
        guard !profile.nameEdited, profile.name.isEmpty else { return }
        profile.name = name
        try write(profile, accountID: accountID)
    }

    public func save(_ profile: UserProfile, accountID: String?) throws {
        var edited = profile
        edited.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.nameEdited = true
        try write(edited, accountID: accountID)
    }

    private func validate(_ profile: UserProfile) throws {
        guard profile.name.count <= Self.maximumNameLength,
              (profile.photoData?.count ?? 0) <= Self.maximumPhotoBytes else { throw UserProfileError.invalidProfile }
    }

    private func write(_ profile: UserProfile, accountID: String?) throws {
        try validate(profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(profile).write(to: file(accountID: accountID), options: options)
    }
}
