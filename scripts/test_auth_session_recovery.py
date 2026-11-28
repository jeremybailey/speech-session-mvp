"""Exercise the production auth manager against a fake SDK; no login or network traffic."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'SpeechSessionApp/KindeAuthManager.swift').read_text()
source = '\n'.join(line for line in source.splitlines() if not line.startswith('import '))
stubs = '''import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<T> { var wrappedValue: T }
struct DefaultLogger {}
struct User {
 var id = "one"
 var email = "test@example.invalid"
 var fullName: String? = "Provider Name"
 var firstName: String? = nil
 var lastName: String? = nil
}
struct UserProfile: Sendable {
 var name = ""
 var photoData: Data? = nil
}
actor UserProfileStore {
 static let shared = UserProfileStore()
 static func appDefault() throws -> UserProfileStore { shared }
 var profiles: [String: UserProfile] = [:]
 var heldOwner: String?
 var heldRead: CheckedContinuation<Void, Never>?
 func seedName(_ name: String, accountID: String) throws {
  if profiles[accountID] == nil { profiles[accountID] = UserProfile(name: name) }
 }
 func save(_ profile: UserProfile, accountID: String) { profiles[accountID] = profile }
 func holdNextRead(for owner: String) { heldOwner = owner }
 func hasHeldRead() -> Bool { heldRead != nil }
 func releaseRead() { heldRead?.resume(); heldRead = nil }
 func load(accountID: String?) async throws -> UserProfile {
  let profile = profiles[accountID ?? "guest"] ?? UserProfile()
  if let accountID, heldOwner == accountID {
   heldOwner = nil
   await withCheckedContinuation { heldRead = $0 }
  }
  return profile
 }
}
struct CloudOpenAIConfiguration {
 static let hasProxy = true
 static func chatCompletionsURL() -> URL? { URL(string:"https://example.invalid/chat") }
 static func audioTranscriptionsURL() -> URL? { URL(string:"https://example.invalid/audio") }
}
enum FastDetailsConfiguration { static let enabled = true }
struct OpenAIChatTransport {
 func fastDetailsTransport() throws -> Self { self }
 let header: @Sendable () async throws -> String
 static func kindeProxy(chatURL: URL, accessToken: @escaping @Sendable () async throws -> String) -> Self { .init(header:accessToken) }
 static func direct(apiKey: String) -> Self { .init(header:{apiKey}) }
}
struct OpenAIWhisperHTTPCredentials {
 let endpointURL: URL
 let header: @Sendable () async throws -> String
 static func openAI(apiKey: String) -> Self { .init(endpointURL:URL(string:"https://example.invalid")!,header:{apiKey}) }
}
@MainActor enum KindeSDKAPI {
 static let auth = FakeAuth()
 static func configure(_ logger: DefaultLogger, fileName: String) {}
}
@MainActor final class FakeAuth {
 var authorized = true
 var user = User()
 var calls = 0
 var fail = false
 func isAuthorized() -> Bool { authorized }
 func isAuthenticated() -> Bool { false } // Expired access token, refreshable session.
 func getUserDetails() -> User? { user }
 func login() async throws { authorized = true }
 func logout() async { authorized = false }
 func getToken() async throws -> String {
 calls += 1
 try await Task.sleep(nanoseconds:20_000_000)
 if fail { throw NSError(domain:"fake",code:1) }
 return "refreshed-token"
 }
}
'''
tests='''
@main struct Tests {
 @MainActor static func main() async throws {
 let manager = KindeAuthManager()
 precondition(manager.isSignedIn, "Expired token must not hide a refreshable session")
 let transport = await manager.openAIChatTransport(byokFallback:"")
 precondition(transport != nil)
 async let first = manager.freshAccessToken()
 async let second = manager.freshAccessToken()
 let tokens = try await (first,second)
 precondition(tokens.0 == "refreshed-token" && tokens.1 == tokens.0 && KindeSDKAPI.auth.calls == 1)
 KindeSDKAPI.auth.fail = true
 do { _ = try await manager.freshAccessToken(); fatalError("expected failure") }
 catch { precondition(manager.sessionNotice != nil && manager.isSignedIn) }
 KindeSDKAPI.auth.authorized = false
 manager.sessionNotice = nil
 let missing = await manager.openAIWhisperCredentials(byokKey:"")
 precondition(missing == nil && manager.sessionNotice != nil && !manager.isSignedIn)
 KindeSDKAPI.auth.fail = false
 try await manager.login()
 precondition(manager.isSignedIn && manager.sessionNotice == nil)
 let profiles = manager.profileStore!
 await profiles.save(UserProfile(name: "Chosen Name", photoData: Data([1])), accountID: "one")
 await manager.refreshProfile()
 precondition(manager.userProfile.name == "Chosen Name" && manager.userProfile.photoData == Data([1]))
 await profiles.save(UserProfile(name: "Chosen Name", photoData: Data([2])), accountID: "one")
 await manager.refreshProfile()
 precondition(manager.userProfile.photoData == Data([2]), "Saved photo must refresh immediately")
 await profiles.holdNextRead(for: "one")
 let oldRead = Task { await manager.refreshProfile() }
 for _ in 0..<1000 {
  if await profiles.hasHeldRead() { break }
  await Task.yield()
 }
 let readStarted = await profiles.hasHeldRead()
 precondition(readStarted, "Expected controlled old-account read")
 await profiles.save(UserProfile(name: "Other Person", photoData: Data([3])), accountID: "two")
 KindeSDKAPI.auth.user = User(id: "two")
 manager.syncState()
 precondition(manager.userProfile.photoData == nil, "Account change must clear the old avatar immediately")
 await manager.refreshProfile()
 precondition(manager.userProfile.photoData == Data([3]))
 await profiles.releaseRead()
 await oldRead.value
 precondition(manager.userProfile.photoData == Data([3]), "Delayed old-account read replaced the current avatar")
 await profiles.holdNextRead(for: "two")
 let stalePhoto = Task { await manager.refreshProfile() }
 for _ in 0..<1000 {
  if await profiles.hasHeldRead() { break }
  await Task.yield()
 }
 let photoReadStarted = await profiles.hasHeldRead()
 precondition(photoReadStarted)
 await profiles.save(UserProfile(name: "Other Person", photoData: Data([4])), accountID: "two")
 await manager.refreshProfile()
 precondition(manager.userProfile.photoData == Data([4]))
 await profiles.releaseRead()
 await stalePhoto.value
 precondition(manager.userProfile.photoData == Data([4]), "An older read replaced the newly saved photo")
 await manager.logout()
 precondition(manager.userProfile.photoData == nil)
 await manager.refreshProfile()
 precondition(manager.userProfile.photoData == nil && manager.userProfile.name.isEmpty)
 print("PASS: auth recovery, immediate avatar refresh, account switching, stale-read rejection and sign-out clearing")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='auth-recovery-') as directory:
 path=Path(directory)
 (path/'Test.swift').write_text(stubs+source+tests)
 subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(path/'cache'),str(path/'Test.swift'),'-o',str(path/'test')],check=True)
 subprocess.run([str(path/'test')],check=True)
