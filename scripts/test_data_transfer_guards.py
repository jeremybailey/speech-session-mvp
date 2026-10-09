"""Offline app-wiring regression checks; archive behavior is tested in Swift."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
settings = (root / "SpeechSessionApp/SettingsView.swift").read_text()
home = (root / "SpeechSessionApp/HomeView.swift").read_text()
model = (root / "SpeechSessionApp/HealthSummaryModel.swift").read_text()
story = (root / "SpeechSessionApp/HealthSummaryView.swift").read_text()
scoped = (root / "SpeechSessionApp/GlobalHealthSummaryView.swift").read_text()
archive = (root / "Sources/SpeechSessionPersistence/DataTransferArchive.swift").read_text()

assert 'NavigationLink("Export data")' in settings
assert 'NavigationLink("Import data")' in settings
assert '@State private var includeOriginals = false' in settings
assert 'SettingsView(isPresented: $showSettings, store: store' in home
assert 'SettingsDataTransferView' not in home
assert 'hasLoaded && !isTransferringData && !isImportedHistory' in model
assert model.count('guard !isProcessing, !isTransferringData') == 4
assert 'isImportedHistory = await store.isImportedHistory' in model
assert story.count('model.automaticProcessingAllowed') == 3
assert scoped.count('if !(await store.isImportedHistory)') == 3
assert 'guard !health.isTransferringData else { return }' in scoped
assert 'importedMarker' in archive and 'incoming.appendingPathComponent(DataTransferArchive.importedMarker)' in archive
assert 'summaryRun = nil' in archive and 'summaryDrafts = nil' in archive
assert 'URLSession' not in archive and 'OpenAI' not in archive
assert 'openAIChatTransport' not in settings.split('struct SettingsView:', 1)[0]
assert 'speechSession.pendingSummaryJob' in settings
assert 'speechSession.globalSummaryJSON' in settings
assert 'await health.resetAfterDataImport()' in settings
assert 'await home.loadSessions()' in settings
assert 'logout()' not in settings.split('struct SettingsView:', 1)[0]
assert 'Words and spaces are fine; numbers and symbols are optional.' in settings
assert 'password.count < DataTransferArchive.minimumPasswordLength' in settings
assert 'Passwords don’t match yet.' in settings
for old_copy in ['Choose export ZIP', 'Export selected', 'Export password', 'Review the export', 'validating export']:
    assert old_copy not in settings, old_copy
print("Settings-only transfer, no automatic inference, and account-preservation guards passed")
