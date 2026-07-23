# Permissions (TCC)

Aloud needs exactly two permissions (plus one conditional third, below). Onboarding requests them one screen at a time with plain-language copy; the app stays alive-but-inert until granted.

## Microphone

- API: `AVCaptureDevice.authorizationStatus(for: .audio)` / `requestAccess(for: .audio)`.
- Info.plist: `NSMicrophoneUsageDescription` — "Aloud uses the microphone to hear what you say while you hold the dictation key. Audio never leaves your Mac."
- Denied → deep link: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
- Status is re-checked on app activation (user may grant in Settings and come back).

## Accessibility

Needed for two things: the global hotkey event tap and the synthetic ⌘V paste.

- Check: `AXIsProcessTrusted()`; prompt: `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
- Deep link: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- Note: a modifier-key event tap can also trip **Input Monitoring** on some configurations; `--doctor` reports both, and onboarding copy tells the user to look in Accessibility first.
- Gotcha: TCC grants are per-binary-path + signature. A dev build at `.build/debug/Aloud` and the installed `/Applications/Aloud.app` are separate grants. After an in-app update, the Developer ID signature keeps the grant valid (same team + bundle id).

## Speech Recognition (conditional — macOS 14/15 basic-dictation fallback only)

Only requested when the user taps "Start Now with Basic Dictation" during onboarding **and** the OS is older than macOS 26 (the modern system pipeline needs no TCC grant; the legacy on-device recognizer does). Never requested at launch or from any quiet path — `AppleSpeechTranscriber.wouldPromptForPermission` gates automatic re-activation.

- Info.plist: `NSSpeechRecognitionUsageDescription` — set in `scripts/make-app.sh`.
- Recognition is forced on-device (`requiresOnDeviceRecognition`); the privacy promise holds.
- Reset for testing: `tccutil reset SpeechRecognition com.abrahamgonzalez.aloud`.

## Onboarding flow (Setup Assistant style)

1. **Welcome** — one sentence on what Aloud does; primary button "Continue".
2. **Microphone** — why + "Allow Microphone" (triggers the system prompt). On denial: explanation + "Open System Settings" deep link + live re-check.
3. **Accessibility** — why ("so your dictation key works everywhere, and Aloud can type for you") + button opens the prompt/pane; polls `AXIsProcessTrusted()` and auto-advances when granted.
4. **Voice setup** — model download with a determinate progress bar ("one-time download, ~500 MB; after this everything stays on your Mac"). Retry button on network failure.
5. **Try it** — a live scratch text field: "Hold ⌘ (right) and say something." Advances to Done when a transcription lands.

Onboarding re-appears (only the unmet screens) if a permission is later revoked.

## Clean-account testing

Create a throwaway macOS user account (System Settings → Users & Groups), log in, drag the DMG build in, walk the checklist in `docs/release.md`. `tccutil reset Microphone com.abrahamgonzalez.aloud && tccutil reset Accessibility com.abrahamgonzalez.aloud` resets grants in the current account for re-testing.
