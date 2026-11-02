# Pre-Option-B fallback

This branch preserves the combined existing processing pipeline, care-plan organization work, and citation/job recovery fixes immediately before the Option B development fork on 2 November 2026.

Build `SpeechSessionApp.xcodeproj` from a clean checkout of `codex/pre-option-b-fallback-2026-11-02`. The normal app pipeline remains the existing staged processing approach. The Care Plan Preview scheme is also retained.

This is a source-code fallback. Switching this branch does not change deployed backend routing, installed apps, patient data, database contents or provider accounting. Any later deployment or release rollback must use the appropriate environment and migration review.

Private patient records, frozen benchmark inputs and outputs, temporary deployment credentials, and local environment files are intentionally excluded. Benchmark source tooling is retained without its private artifacts.
