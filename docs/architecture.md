# Architecture

One SwiftPM executable target (`Aloud`). Every file compiles into a single module; top-level code only in `main.swift`. The app bundle is staged by `scripts/make-app.sh` (SPM builds the binary, the script wraps it with Info.plist + icon + signature).

## Dual mode, dispatched in `main.swift`

- **CLI mode** (`--selftest`, `--transcribe`, `--transcribe-live`, `--inject`, `--doctor`, `--version`, `--reset`): does its work headlessly, exits. This is how agents and CI verify subsystems without a GUI.
- **GUI mode** (no args): singleton lock, `NSApplication` menu bar app (`LSUIElement`, no Dock icon).

## The push-to-talk loop

```
hold hotkey ──▶ HotkeyManager (CGEventTap)
                  │ keyDown
                  ▼
              AudioRecorder (AVAudioEngine tap → 16 kHz mono Float32 buffer)
                  │ keyUp (≥ min hold; short taps ignored)
                  ▼
              Transcriber.transcribe(samples) — async, off-main
                  │ text
                  ▼
              TextInjector: save NSPasteboard → set text → synthetic ⌘V → restore pasteboard
                  ▼
              HistoryStore.append (local JSON, user-clearable)
```

- `RecordingIndicator`: a small floating `NSPanel` (non-activating, joins all Spaces) with a SwiftUI pulsing waveform, shown only while the key is held. Feedback must be instant (<50 ms) so the user trusts it's listening.
- **Live typing (beta, off by default).** With the Settings toggle on, a `StreamingTranscription` session re-decodes the whole captured buffer through the normal batch pipeline every ~1 s (full-context hypothesis, so later speech revises earlier words), and `LiveTyper` keeps the focused app in sync — backspacing to the point of divergence and retyping via CGEvent unicode keystrokes with cleared modifier flags (the user is still physically holding the hotkey). On release the full buffer goes through the same batch path one final time and a last diff pass settles the screen, so the end result is identical to non-live mode. A click mid-dictation freezes the typer (the cursor moved; edits would land in the wrong place). Cancel erases everything typed. Headless check: `Aloud --transcribe-live <file> [speed]`; GUI loop: `LIVE=1 bash scripts/loop-test.sh`.
- Hotkey default: **Right ⌥ (hold)** — Fn is intercepted by the system for dictation/emoji, F-keys collide with media keys, and ⌘/⌃ are navigation modifiers that would poison clicks and keystrokes made while the key is held. Rebindable in Settings via a recorder control. Modifier-only hotkeys come from `flagsChanged` events; regular keys from `keyDown`/`keyUp`.
- Hands-free (Settings toggle, on by default): double-press the key → recording locks on with nothing held; further hotkey presses are ignored and **Esc finishes + commits**. With the toggle off, double-press never locks.
- Cancel: press Esc while *holding* → discard recording, nothing typed.

## Subsystems

| Dir | Responsibility | Key types |
|---|---|---|
| `App/` | entry, AppDelegate, status item + menu, window management | `AppDelegate`, `StatusItemController` |
| `Hotkey/` | CGEventTap; hold/release detection; rebindable combo | `HotkeyManager`, `Hotkey` (Codable) |
| `Audio/` | AVAudioEngine input tap; device picker; resample to 16 kHz mono | `AudioRecorder` |
| `Transcription/` | `Transcriber` protocol; FluidAudio-backed impl; model download/progress | `Transcriber`, `ParakeetTranscriber`, `ModelManager` |
| `Injection/` | pasteboard save/restore + synthetic ⌘V via CGEvent; live diff-typing | `TextInjector`, `LiveTyper`, `TypedTextDiff` |
| `Permissions/` | mic (AVCaptureDevice) + accessibility (AXIsProcessTrusted) status, System Settings deep links | `Permissions` |
| `UI/` | onboarding window, settings window, recording indicator | SwiftUI views |
| `Support/` | UserDefaults-backed settings, history, login item (SMAppService), self-updater | `Settings`, `HistoryStore`, `Updater` |

## Design rules

- `Transcriber` is a protocol. The engine (currently FluidAudio + Parakeet CoreML) is an implementation detail — swappable, never named in UI.
- All transcription/model work off the main thread; UI state via `@MainActor` observable objects.
- No network at runtime except: one-time model download, daily release update check (both plain HTTPS GET to fixed hosts, no identifiers sent).
- State on disk: `~/Library/Application Support/Aloud/` (settings via UserDefaults, history JSON, models dir).

## Reliability principles (local-first)

Faults must not become failures — every local fault path degrades, never corrupts:

- **Atomic writes everywhere.** History persists with `.atomic`; settings go through UserDefaults (cfprefsd is transactional); the updater swap is staged → verified → atomically moved with rollback, so a failed update never leaves the user without a working app.
- **Data outlives code.** On-disk formats (history, hotkey JSON, doctor output) decode leniently; an unreadable history file is set aside as `.bak`, never overwritten. Schema changes must stay backward-readable.
- **Idempotent retries.** Model prepare() is safe to call repeatedly and concurrent callers share one download; a partial download resumes rather than restarts.
- **Trust, but verify inputs.** The updater refuses any bundle whose signature seal or Developer ID team doesn't verify; transcription errors surface as a visible hint, never a silent drop.
- **End-to-end clipboard safety.** The pasteboard snapshot is restored on a timer armed at inject time, regardless of what the transcription path does afterwards.
