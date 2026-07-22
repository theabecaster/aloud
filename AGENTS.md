# Aloud — agent guide

Aloud is a macOS menu bar dictation app: hold a hotkey, speak, release — text appears in the focused app. Transcription is fully on-device (CoreML speech model via the FluidAudio SDK). No accounts, no telemetry, no runtime network use after the one-time model download.

## Build & run

```sh
swift build                    # debug build
swift build -c release         # release build
swift test                     # unit tests
bash scripts/make-app.sh       # stage dist/Aloud.app (signed if CODESIGN_IDENTITY set)
```

Target: macOS 14+, Swift 6, SPM executable package (no .xcodeproj). App bundle is assembled by `scripts/make-app.sh`.

## Test without a human

The binary has headless CLI modes so agents can verify subsystems without GUI interaction — use them after every change:

```sh
.build/debug/Aloud --selftest              # in-process checks of every subsystem (no permissions needed)
.build/debug/Aloud --transcribe <wav>      # transcribe a file, print text to stdout (downloads model if absent)
.build/debug/Aloud --inject "text"         # clipboard-paste injection path (needs Accessibility)
.build/debug/Aloud --doctor                # print permission/model/config status as JSON
.build/debug/Aloud --simulate-hold 3       # synthetically hold the hotkey (drives the live GUI's tap)
.build/debug/Aloud --update-check          # probe the release feed (never installs)
```

Full loop verification: `bash scripts/e2e.sh` (synthesized speech → transcribe → WER; plus --inject into TextEdit). Highest-fidelity: `bash scripts/loop-test.sh` — drives the installed GUI app's real tap with a synthetic hotkey hold while playing speech through the speakers, then asserts the text landed in TextEdit. Model evals: `bash eval/run-eval.sh` (see `docs/testing.md`).

## Source map

- `Sources/Aloud/App/` — entry point, AppDelegate, status item, windows
- `Sources/Aloud/Hotkey/` — CGEventTap push-to-talk capture
- `Sources/Aloud/Audio/` — AVAudioEngine mic capture → 16 kHz mono Float32
- `Sources/Aloud/Transcription/` — `Transcriber` protocol + FluidAudio/Parakeet impl + model download
- `Sources/Aloud/Injection/` — clipboard save → Cmd-V → restore
- `Sources/Aloud/Permissions/` — mic + accessibility checks, System Settings deep links
- `Sources/Aloud/UI/` — SwiftUI onboarding, settings, recording indicator
- `Sources/Aloud/Support/` — settings store, history store, login item, updater

## Rules

- UI: native SwiftUI + SF Symbols only. No custom controls, no custom fonts, no third-party UI kits. System materials for panels. If in doubt: make it look like System Settings.
- Never add telemetry, analytics, or network calls beyond model download + release update check.
- The transcription engine stays behind the `Transcriber` protocol — model choice is an implementation detail; never surface the model name in UI.
- Conventional Commits; release automation derives versions from them.
- Branches: `dev` is the integration branch, `main` releases. PRs into `main` cut releases automatically (see `docs/release.md`).

## Deep docs

- `docs/architecture.md` — subsystem design, data flow, threading
- `docs/testing.md` — selftest, e2e, eval harness, CI gates
- `docs/release.md` — versioning, signing, notarization, update pipeline
- `docs/permissions.md` — TCC details, deep links, clean-account testing
