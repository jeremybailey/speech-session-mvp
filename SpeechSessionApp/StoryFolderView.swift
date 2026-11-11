import SwiftUI
import UIKit
import SpeechSessionFeatures
import SpeechSessionPersistence

enum StoryRoute: Hashable {
    case folders, carePlan, allDetails, folder(UUID), record(UUID), fact(String, UUID?, SummaryEntry?)
}

final class StoryFolderRouter: ObservableObject {
    @Published var path: [StoryRoute] = []
    @Published var lastDeleted: SessionFolder?
    @Published var capture: Session?
    var onCaptureDismiss: (() -> Void)?
    var finishedCapture: UUID?
    func newCapture() {
        guard capture == nil else { return }
        var record = Session(transcript: "", inputType: .document, sourceAssets: [])
        record.capture = RecordCapture()
        capture = record
    }
    var captureExcerpt: (id: UUID, quote: String)?
    var requestedOriginal: UUID?

    func open(_ route: StoryRoute) {
        if let index = path.firstIndex(where: {
            if case let .fact(a, _, _) = $0, case let .fact(b, _, _) = route { return a == b }
            return $0 == route
        }) {
            if case let .record(id) = route { requestedOriginal = id }
            path.removeSubrange((index + 1)..<path.count)
        } else {
            path.append(route)
        }
    }
}

private enum RouterKey: EnvironmentKey { static let defaultValue: StoryFolderRouter? = nil }
extension EnvironmentValues {
    var storyRouter: StoryFolderRouter? {
        get { self[RouterKey.self] }
        set { self[RouterKey.self] = newValue }
    }
}

struct StoryFolderDestination: View {
    let route: StoryRoute
    let store: SessionStore
    @ObservedObject var home: HomeViewModel
    @EnvironmentObject private var health: HealthSummaryModel
    let carePlan: () -> AnyView
    var body: some View {
        if !health.hasLoaded { StoryLoadingPlaceholder(label: "Loading health details") .padding() }
        else if health.snapshotReadFailed && health.snapshot.sessions.isEmpty {
            ContentUnavailableView { Label("Couldn’t load your records", systemImage:"doc.text") } actions: { Button("Retry"){Task{await health.refresh()}} }
        } else { destination }
    }
    @ViewBuilder private var destination: some View {
        switch route {
        case .carePlan: carePlan().navigationTitle("My care plan").navigationBarTitleDisplayMode(.inline)
        case .folders: StoryFolderBrowser(store: store)
        case .allDetails:
            HealthSummaryView(model: health, home: home, store: store, structuredOnly: true)
                .navigationTitle("All details")
        case .folder(let id): StoryFolderPage(id: id, store: store)
        case .record(let id):
            if let record = health.snapshot.sessions.first(where: { $0.id == id }) ?? home.sessions.first(where: { $0.id == id }) {
                SessionDetailView(session: record, store: store, home: home)
            } else { ContentUnavailableView("Record unavailable", systemImage: "doc") }
        case let .fact(id, entry, original):
            HealthFactDetailView(factID: id, preferredEntryID: entry, sourceOnlyEntry: original,
                                 model: health, home: home, store: store)
        }
    }
}

private extension SessionFolder {
    var symbol: String {
        guard let bodySystem, let area = HealthAreaKind(rawValue: bodySystem), area != .other else { return "folder" }
        return UIImage(systemName: area.symbol) == nil ? "folder" : area.symbol
    }
}

private struct StoryFolderBrowser: View {
    let store: SessionStore
    @EnvironmentObject private var health: HealthSummaryModel
    @Environment(\.storyRouter) private var router
    @State private var query = ""
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        List {
            CreateFolderButton { creating = true }
            NavigationLink(value: StoryRoute.allDetails) { Label("All details", systemImage: "square.grid.2x2") }
            if let deleted = router?.lastDeleted {
                Button("Undo deletion of " + deleted.name, systemImage: "arrow.uturn.backward") {
                    Task {
                        do {
                            try await store.setRecordFolderDeleted(false, folder: deleted)
                            await health.refresh()
                            router?.lastDeleted = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            Section {
                ForEach(health.recordFolders.folders.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { folder in
                    NavigationLink(value: StoryRoute.folder(folder.id)) {
                        HStack {
                            StoryRecordIcon(symbol: folder.symbol)
                            VStack(alignment: .leading) {
                                Text(folder.name).font(StoryDesignTokens.label)
                                let count = health.recordFolders.recordIDs[folder.id]?.count ?? 0
                                Text(count == 1 ? "1 record" : "\(count) records")
                                    .font(StoryDesignTokens.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Conditions")
        .searchable(text: $query, prompt: "Search conditions")
        .sheet(isPresented: $creating) {
            FolderForm(title: "Create condition", folder: SessionFolder(name: "")) { folder in
                try await store.upsertFolder(folder)
                await health.refresh()
            }
        }
        .folderError($error)
    }
}

private struct StoryFolderPage: View {
    let id: UUID
    let store: SessionStore
    @EnvironmentObject private var health: HealthSummaryModel
    @Environment(\.storyRouter) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var editTitle: String?
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        if let folder = health.recordFolders.selectableFolders.first(where: { $0.id == id }) {
            let ids = health.recordFolders.recordIDs[id] ?? []
            List {
                if ids.isEmpty { ContentUnavailableView("No records yet", systemImage: folder.symbol) }
                StoryTimelineSections(records: health.snapshot.sessions.filter { ids.contains($0.id) })
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(StoryDesignTokens.canvas)
            .navigationTitle(folder.name)
            .toolbar {
                Menu {
                    Button("Rename", systemImage: "pencil") { editTitle = "Rename condition" }
                    Button("Change body system", systemImage: "figure.stand") { editTitle = "Change body system" }
                    Button("Delete condition", systemImage: "trash", role: .destructive) { confirming = true }
                } label: { Label("Condition actions", systemImage: "ellipsis") }
            }
            .sheet(isPresented: Binding(get: { editTitle != nil }, set: { if !$0 { editTitle = nil } })) {
                FolderForm(title: editTitle ?? "Edit condition", folder: folder) { changed in
                    try await store.upsertFolder(changed)
                    await health.refresh()
                }
            }
            .confirmationDialog("Delete this condition?", isPresented: $confirming) {
                Button("Delete condition", role: .destructive) {
                    Task {
                        do {
                            try await store.setRecordFolderDeleted(true, folder: folder)
                            router?.lastDeleted = folder
                            dismiss()
                            await health.refresh()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            } message: { Text("Your records will stay in My health story.") }
            .folderError($error)
        } else { ContentUnavailableView("Condition unavailable", systemImage: "folder") }
    }
}

private struct FolderForm: View {
    let title: String
    @State var folder: SessionFolder
    let save: (SessionFolder) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if title != "Change body system" { TextField("Condition name", text: $folder.name) }
                if title != "Rename condition" {
                    Picker("Body system", selection: Binding(get: { folder.bodySystem ?? "other" }, set: { folder.bodySystem = $0 })) {
                        ForEach(HealthAreaKind.allCases, id: \.self) { area in
                            Text(area == .other ? "Unspecified" : area.title).tag(area.rawValue)
                        }
                    }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do {
                                folder.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                try await save(folder)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(saving || folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .folderError($error)
        }
    }
}

struct RecordFolderChips: View {
    let recordID: UUID
    let edit: () -> Void
    @EnvironmentObject private var health: HealthSummaryModel
    var body: some View {
        let ids = health.recordFolders.memberships[recordID] ?? []
        let folders = health.recordFolders.folders.filter { ids.contains($0.id) }
        ScrollView(.horizontal) {
            HStack {
                if folders.isEmpty { Button("Add to condition", systemImage: "folder.badge.plus", action: edit) }
                ForEach(folders) { folder in
                    Button(folder.name, systemImage: folder.symbol, action: edit)
                        .accessibilityHint("Change conditions for this record")
                }
            }.buttonStyle(.bordered).buttonBorderShape(.capsule).padding(.horizontal)
        }.scrollIndicators(.hidden)
    }
}

struct RecordFolderPicker: View {
    let recordID: UUID
    let store: SessionStore
    @EnvironmentObject private var health: HealthSummaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var initial: Set<UUID> = []
    @State private var drafts: [SessionFolder] = []
    @State private var loaded = false
    @State private var creating = false
    @State private var saving = false
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        let folders = health.recordFolders.selectableFolders + drafts
        NavigationStack {
            List {
                CreateFolderButton { creating = true }
                ForEach(folders.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { folder in
                    Button {
                        if selection.contains(folder.id) { selection.remove(folder.id) } else { selection.insert(folder.id) }
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: folder.symbol).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selection.contains(folder.id) ? "checkmark.circle.fill" : "circle")
                        }.frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(selection.contains(folder.id) ? .isSelected : [])
                }
            }
            .searchable(text: $query, prompt: "Search conditions")
            .navigationTitle("Record conditions").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !loaded else { return }
                initial = health.recordFolders.memberships[recordID] ?? []
                selection = initial
                loaded = true
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do {
                                try await store.setRecordFolders(recordID: recordID, folders: folders.filter { selection.contains($0.id) })
                                await health.refresh()
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(saving || !loaded || selection == initial)
                }
            }
            .sheet(isPresented: $creating) {
                FolderForm(title: "Create condition", folder: SessionFolder(name: "")) { folder in
                    drafts.append(folder)
                    selection.insert(folder.id)
                    query = ""
                }
            }
            .interactiveDismissDisabled(saving)
            .folderError($error)
        }
    }
}

private extension View {
    func folderError(_ message: Binding<String?>) -> some View {
        alert("Could not save condition changes", isPresented: Binding(get: { message.wrappedValue != nil }, set: {
            if !$0 { message.wrappedValue = nil }
        })) { Button("OK") { message.wrappedValue = nil } } message: { Text(message.wrappedValue ?? "") }
    }
}

private struct CreateFolderButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "folder.badge.plus").accessibilityHidden(true)
                Text("Create condition")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}
