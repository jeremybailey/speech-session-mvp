# CollectiveCare Release Notes

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

## Testing checklist

- [ ] Import a PDF and confirm Source tab shows the original document
- [ ] Take a photo or document scan and verify image pages appear in Source
- [ ] Record or import audio and confirm playback in Source
- [ ] Tap **View source** on a summary card — session detail switches to Source; health summary navigates to Source
- [ ] Share from Source tab — file is shared, not transcript text (for new imports)
- [ ] Open an older session — Source shows transcript fallback with “original not available” banner
- [ ] Share health summary as PDF and confirm typography layout
