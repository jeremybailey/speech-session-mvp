import UIKit
import SwiftUI
import SpeechSessionPersistence

@main
struct SpeechSessionAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel: AppModel
    @StateObject private var kindeAuth = KindeAuthManager()

    init() {
        FounderLoadAudit.mark("start")
        StoryDesignTokens.configureNavigationTypography()
        do {
            let store = try SessionStore.appDefault()
            _appModel = StateObject(wrappedValue: AppModel(store: store))
        } catch {
            fatalError("Could not open saved entries: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(appModel: appModel, kindeAuth: kindeAuth)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        Task { @MainActor in
            for context in options.urlContexts {
                let url = context.url
                guard !KindeAuthManager.isKindeOAuthCallbackURL(url) else { continue }
                SharedImportURLInbox.shared.enqueue(url)
            }
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard !KindeAuthManager.isKindeOAuthCallbackURL(url) else { return true }
        Task { @MainActor in
            SharedImportURLInbox.shared.enqueue(url)
        }
        return true
    }
}

// Optional founder-device launch timing. Only stage names and elapsed time are emitted.
@MainActor enum FounderLoadAudit {
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--founder-load-audit")
    private static let start = ProcessInfo.processInfo.systemUptime
    private static var seen = Set<String>()
    #endif

    static func mark(_ stage: String) {
        #if DEBUG
        guard enabled, seen.insert(stage).inserted else { return }
        let origin = start
        let ms = Int((ProcessInfo.processInfo.systemUptime - origin) * 1000)
        FileHandle.standardOutput.write(Data("FOUNDER_LOAD \(stage) \(ms) ms\n".utf8))
        #endif
    }
}
