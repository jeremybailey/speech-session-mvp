# Collective Care V2 — TestFlight upload, November 22, 2026

User authorized GitHub publication and TestFlight upload after accepting the summaries navigation, PDF preview and matching background on the founder phone.

- App: Collective Care V2, `com.CollectiveCare.storylab`.
- Version/build: **1.0993 (222)**.
- Archived source: `064ab54daa89db5c3edc20db636ca7398b58dc05`.
- Source digest: `dd7c9c35414dbe2b7987de69afbd45bea28c05ddaeda5efe5431acd2b36abd4a`.
- GitHub branch: `codex/editable-health-story`.
- Upload completed at 09:54:50 Eastern. Xcode reported **Upload succeeded / EXPORT SUCCEEDED**; Apple reported processing. Tester availability and distribution are not independently verified.

## Changes

- More Summaries opens Practitioner summary and Care plan summary.
- Home Share control moved inside summaries alongside Regenerate/recovery.
- Both Share controls open PDF preview before presenting the share sheet.
- Care plan export contains care-plan content, with following-now actions separate from recorded recommendations.
- Summary list and rows use the home canvas in light and dark appearances.

## Verification

Debug build 222 compiled and installed on the founder iPhone. Release archive succeeded; its bundle identifier, build number, Git commit and complete source digest matched the checkout before upload. `git diff --check` passed. This is a UI/export release; no service deployment or pilot distribution was performed.

Pilot source comparison and proposed promotion gates are in `PilotPromotion-2026-11-22.md`.
