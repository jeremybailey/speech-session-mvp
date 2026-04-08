import Combine
import Foundation
import SpeechSessionPersistence

@MainActor
public final class HomeViewModel: ObservableObject {
    private let store: SessionStore

    @Published public private(set) var sessions: [Session] = []

    public init(store: SessionStore) {
        self.store = store
    }

    public func loadSessions() async {
        do {
            let all = try await store.loadAll()
            sessions = all.sorted { $0.date > $1.date }
        } catch {
            sessions = []
        }
    }

    public func delete(session: Session) async {
        // Remove immediately from the published array so the animation is instant.
        sessions.removeAll { $0.id == session.id }
        try? await store.delete(id: session.id)
    }
}
