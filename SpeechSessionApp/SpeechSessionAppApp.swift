import SwiftUI
import SpeechSessionPersistence

@main
struct SpeechSessionAppApp: App {
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
        }
    }
}
