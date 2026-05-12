import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

/// Navigation target for the entries list (Voice Memos–style).
enum EntryListScope: Hashable {
    case all
    case folder(UUID)

    var defaultFolderID: UUID? {
        switch self {
        case .all: nil
        case .folder(let id): id
        }
    }
}

/// Pushes `ScopedHealthSummaryView` for the same scope as the entry list.
struct SummaryNavigationMarker: Hashable {
    let scope: EntryListScope
}

/// Root shelf: “All entries” + user folders (like iOS Voice Memos).
struct EntriesShelfView: View {
    @ObservedObject var home: HomeViewModel
    let store: SessionStore

    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    var body: some View {
        List {
            Section {
                NavigationLink(value: EntryListScope.all) {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        Text("All entries")
                        Spacer()
                        Text("\(home.sessions.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("My folders") {
                if home.folders.isEmpty {
                    Text("No folders yet. Open an entry list and use the plus button to add entries, or create a folder here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(home.folders) { folder in
                    NavigationLink(value: EntryListScope.folder(folder.id)) {
                        HStack(spacing: 14) {
                            Image(systemName: "folder")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.blue)
                                .frame(width: 28)
                            Text(folder.name)
                            Spacer()
                            Text("\(home.sessions.filter { $0.folderID == folder.id }.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteFolders)
            }
        }
        .navigationTitle("Entries")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newFolderName = ""
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("New folder")
            }
        }
        .alert("New folder", isPresented: $showNewFolderAlert) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
        } message: {
            Text("Folders help you group related visit notes.")
        }
        .task {
            await home.loadSessions()
        }
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folder = SessionFolder(name: trimmed)
        Task {
            try? await store.upsertFolder(folder)
            await home.loadSessions()
        }
    }

    private func deleteFolders(at offsets: IndexSet) {
        Task {
            for index in offsets {
                let folder = home.folders[index]
                try? await store.deleteFolder(id: folder.id)
            }
            await home.loadSessions()
        }
    }
}
