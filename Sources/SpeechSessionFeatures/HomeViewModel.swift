import Combine
import Foundation
import SpeechSessionPersistence

@MainActor
public final class HomeViewModel: ObservableObject {
    private let store: SessionStore

    @Published public private(set) var sessions: [Session] = []
    @Published public private(set) var folders: [SessionFolder] = []
    @Published public private(set) var revision = 0
    @Published public var errorMessage: String?

    public init(store: SessionStore) {
        self.store = store
    }

    public func loadSessions() async {
        do {
            let snapshot = try await store.healthSnapshot()
            sessions = snapshot.sessions.sorted { $0.date > $1.date }
            revision += 1
            folders = snapshot.folders.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            errorMessage = "Your records could not be loaded. Please try again."
        }
    }

    public func delete(session: Session) async {
        do {
            try await store.delete(id: session.id)
            await loadSessions()
        } catch { errorMessage = "The record could not be deleted. Please try again." }
    }
}
