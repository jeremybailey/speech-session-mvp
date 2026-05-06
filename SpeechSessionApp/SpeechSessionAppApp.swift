import UIKit
import SwiftUI
import SpeechSessionPersistence

@main
struct SpeechSessionAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel: AppModel

    init() {
        do {
            let store = try SessionStore.appDefault()
            _appModel = StateObject(wrappedValue: AppModel(store: store))
        } catch {
            fatalError("Could not open session store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .onOpenURL { url in
                    SharedAudioURLInbox.shared.enqueue(url)
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
                SharedAudioURLInbox.shared.enqueue(context.url)
            }
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Task { @MainActor in
            SharedAudioURLInbox.shared.enqueue(url)
        }
        return true
    }
}
