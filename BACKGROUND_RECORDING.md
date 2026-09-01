# Background Session Recording — Manual Test Checklist

Live appointment capture should continue when the app backgrounds or the device sleeps. On Stop, transcription prefers the on-disk `recording.caf` for Whisper backends and falls back to file transcription for Apple Speech when live text is empty.

## Prerequisites

- Physical iPhone (simulator background audio behavior is unreliable)
- Microphone permission granted
- Test each transcription backend you ship: Apple Speech, WhisperKit, OpenAI Whisper (if configured)

## Tests

### Lock screen (2+ minutes)

1. Start a recording and speak for ~10 seconds.
2. Lock the phone for at least 2 minutes; say a few more sentences near the mic before unlocking.
3. Unlock, return to the app, tap **Stop**.
4. **Expect:** Full transcript includes speech from before and after lock; **Source** tab has `recording.caf`.

### App switch

1. Start recording, speak briefly.
2. Switch to another app (e.g. Notes) for 1–2 minutes.
3. Return to CollectiveCare; status may show **Recording in background** briefly after return.
4. Stop recording.
5. **Expect:** No silent gap in transcript; audio asset saved.

### Phone call interruption

1. Start recording.
2. Trigger an interruption (incoming call or Siri).
3. **Expect:** UI shows **Paused — call or system audio**; timer pauses.
4. End the interruption.
5. Speak again, then Stop.
6. **Expect:** Capture resumes automatically; transcript includes post-call speech.

### WhisperKit / OpenAI Whisper stop path

1. Start recording with WhisperKit or OpenAI Whisper backend.
2. Background or lock briefly, then Stop.
3. **Expect:** Transcript comes from the saved CAF (spinner while transcribing); not dependent on in-memory live buffers.

### Apple Speech live + fallback

1. Start recording with Apple Speech.
2. Confirm live partials appear while foregrounded.
3. Lock/unlock, confirm partials resume after unlock.
4. Stop and verify transcript completeness.
5. (Optional) If live text is empty after a bad session, Stop should still attempt file-based transcription.

### Source tab

After any backgrounded session, open the saved entry → **Source** tab and confirm the recording file is present and playable.

## Regression

- Recording does **not** auto-stop when backgrounding.
- Idle state: no background audio session after Stop.
- Import-audio and scan flows unchanged.

## Live Activity (lock screen)

While recording or transcribing, a Live Activity appears on the lock screen and Dynamic Island with:

- Live timer (auto-updating during capture)
- **Stop** button while recording
- **Transcribing…** state after Stop until transcription finishes

Stop from the lock screen ends the visit capture without unlocking the phone. Starting a new recording from the lock screen opens the app (mic permission requires the foreground app).

Ensure Live Activities are enabled for CollectiveCare in **Settings → CollectiveCare → Live Activities**.
