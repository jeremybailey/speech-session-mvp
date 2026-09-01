# CollectiveCare Release Notes

## Version 1.095

### Lock screen Live Activity while recording

Record and transcribe with controls visible on the lock screen and Dynamic Island.

- **Live Activity** appears while capturing or finishing transcription — plum branding with heart icon and live timer
- **Stop from lock screen** ends capture without unlocking the phone
- **Compact Dynamic Island** layout — heart + timer in the pill; expanded view stays tight
- Duplicate-save bug fixed when stopping from the Live Activity

### Background session recording

Recording continues when the app is backgrounded or the device sleeps (Granola-style continuous capture).

- **Background audio mode** keeps the mic pipeline alive during visits and journal entries
- **Interruption recovery** after calls, route changes, and media resets
- **File-first transcription** on Stop for Whisper backends; Apple Speech falls back to the saved CAF when live text is empty
- **Status in UI** — “Recording in background” and “Paused — call or system audio”

See `BACKGROUND_RECORDING.md` for a device test checklist.

### Traceable summary sources

Summary facts link back to the original entry they came from.

- **Source citation** on each summary card row — tap to open the original entry’s Source tab with excerpt highlight
- **Health summary** navigates to full entry detail (not just the file viewer) so context is preserved
- **Provenance** in the card editor is tappable when a source entry exists

---

## Version 1.093

### Source verification for summary entries

Practitioners can now open the original material behind any summarized fact.

- **Source tab** replaces Transcription on session detail — view PDFs, photos, scans, audio, and plain-text files
- **View source** on summary cards (session detail and health summary) jumps to the underlying file with optional excerpt context
- **Original files are kept** when importing PDFs, images, document scans, audio files, and live recordings
- **Share from Source** sends the actual file when available; legacy entries without saved files fall back to extracted text
- **Legacy sessions** show a clear banner and read-only transcript when the original upload was not retained

### Print-ready health summary PDFs

*(included in 1.092, still part of this build)*

- Share formatted PDF health summaries from session detail or the global health summary
- White, typography-based layout with heading hierarchy and bulleted entries
- Metadata indented under each bullet for clean clinical reading

### Summary cards

*(from recent releases, still active in this build)*

- Entries grouped by clinical status: Active → Resolved → Inactive
- Stacked sources for repeated facts across visits
- Liquid glass card styling with practitioner and date on each row

---

## Testing checklist (1.095)

- [ ] Start recording → lock phone 2+ min → unlock → Stop → full transcript and Source audio saved
- [ ] Live Activity shows on lock screen with timer; Stop saves exactly one entry
- [ ] Summary card source link opens original entry Source tab with excerpt
- [ ] Health summary source link opens entry detail on Source tab
- [ ] Background / interrupted status strings appear when applicable

## Testing checklist (1.093)

- [ ] Import a PDF and confirm Source tab shows the original document
- [ ] Take a photo or document scan and verify image pages appear in Source
- [ ] Record or import audio and confirm playback in Source
- [ ] Tap **View source** on a summary card — session detail switches to Source; health summary navigates to Source
- [ ] Share from Source tab — file is shared, not transcript text (for new imports)
- [ ] Open an older session — Source shows transcript fallback with “original not available” banner
- [ ] Share health summary as PDF and confirm typography layout
