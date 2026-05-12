import Combine
import Foundation
import SpeechSessionPersistence

@MainActor
public final class HomeViewModel: ObservableObject {
    private let store: SessionStore

    @Published public private(set) var sessions: [Session] = []
    @Published public private(set) var folders: [SessionFolder] = []

    public init(store: SessionStore) {
        self.store = store
    }

    public func loadSessions() async {
        do {
            let all = try await store.loadAll()
            sessions = all.sorted { $0.date > $1.date }
            folders = try await store.loadFolders().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            sessions = []
            folders = []
        }
    }

    public func delete(session: Session) async {
        // Remove immediately from the published array so the animation is instant.
        sessions.removeAll { $0.id == session.id }
        try? await store.delete(id: session.id)
    }
}
