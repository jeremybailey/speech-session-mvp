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
struct User { var email: String = "test@example.invalid" }
struct CloudOpenAIConfiguration {
 static let hasProxy = true
 static func chatCompletionsURL() -> URL? { URL(string:"https://example.invalid/chat") }
 static func audioTranscriptionsURL() -> URL? { URL(string:"https://example.invalid/audio") }
}
struct OpenAIChatTransport {
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
 var calls = 0
 var fail = false
 func isAuthorized() -> Bool { authorized }
 func isAuthenticated() -> Bool { false } // Expired access token, refreshable session.
 func getUserDetails() -> User? { User() }
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
 print("PASS: expired session refresh, coalesced requests, refresh-failure notice, signed-out notice, and login recovery")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='auth-recovery-') as directory:
 path=Path(directory)
 (path/'Test.swift').write_text(stubs+source+tests)
 subprocess.run(['swiftc','-parse-as-library','-module-cache-path',str(path/'cache'),str(path/'Test.swift'),'-o',str(path/'test')],check=True)
 subprocess.run([str(path/'test')],check=True)
