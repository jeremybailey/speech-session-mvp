import SwiftUI
import SpeechSessionPersistence

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appModel: AppModel

    @State private var navPath = NavigationPath()
    @State private var didBootstrapEntriesNavigation = false

    var body: some View {
        NavigationStack(path: $navPath) {
            EntriesShelfView(home: appModel.home, store: appModel.store)
                .navigationDestination(for: EntryListScope.self) { scope in
                    HomeView(
                        home: appModel.home,
                        recording: appModel.recording,
                        store: appModel.store,
                        listScope: scope,
                        pendingSharedImportURL: $appModel.pendingSharedImportURL,
                        advanceSharedImportQueue: appModel.enqueuePendingSharedImportIfAvailable
                    )
                    .navigationDestination(for: Session.self) { session in
                        SessionDetailView(session: session, store: appModel.store, home: appModel.home)
                    }
                }
        }
        .onAppear {
            if !didBootstrapEntriesNavigation {
                didBootstrapEntriesNavigation = true
                navPath.append(EntryListScope.all)
            }
        }
        .onChange(of: appModel.pendingSharedImportURL) { _, newValue in
            guard newValue != nil else { return }
            navPath = NavigationPath()
            navPath.append(EntryListScope.all)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            appModel.enqueuePendingSharedImportIfAvailable()
        }
    }
}
