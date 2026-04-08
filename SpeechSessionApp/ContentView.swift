import SwiftUI
import SpeechSessionPersistence

struct ContentView: View {
    @ObservedObject var appModel: AppModel

    /// Per-tab navigation path for the Sessions stack.
    @State private var navPath = NavigationPath()

    var body: some View {
        TabView {
            // MARK: Sessions tab
            Tab("Sessions", systemImage: "waveform.circle.fill") {
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

            // MARK: Health Summary tab
            Tab("Summary", systemImage: "heart.text.square.fill") {
                GlobalHealthSummaryView(home: appModel.home, store: appModel.store)
            }
        }
    }
}
