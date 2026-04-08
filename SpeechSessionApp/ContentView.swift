import SwiftUI
import SpeechSessionPersistence

struct ContentView: View {
    @ObservedObject var appModel: AppModel

    /// Shared navigation path — allows any view in the stack to programmatically push/replace.
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            HomeView(
                home: appModel.home,
                recording: appModel.recording,
                store: appModel.store
            )
            .navigationDestination(for: Session.self) { session in
                SessionDetailView(session: session, store: appModel.store)
            }
        }
    }
}
