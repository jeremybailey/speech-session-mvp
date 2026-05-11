import UIKit
import SwiftUI
import SpeechSessionPersistence

@main
struct SpeechSessionAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel: AppModel
    @StateObject private var kindeAuth = KindeAuthManager()

    init() {
        do {
            let store = try SessionStore.appDefault()
            _appModel = StateObject(wrappedValue: AppModel(store: store))
        } catch {
            fatalError("Could not open saved entries: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .environmentObject(kindeAuth)
                .onOpenURL { url in
                    guard !KindeAuthManager.isKindeOAuthCallbackURL(url) else { return }
                    SharedImportURLInbox.shared.enqueue(url)
                }
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
