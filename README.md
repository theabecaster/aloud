# Aloud

**Say it aloud. It types.**

Aloud is a macOS menu bar dictation app. Hold a key, speak, let go — your words appear in whatever app you're typing in. That's the whole product.

- **Private by design.** Speech is transcribed entirely on your Mac. Audio never leaves your machine — no cloud, no account, no subscription, no telemetry.
- **Works everywhere.** Terminal, browser, notes, chat — anywhere a cursor blinks.
- **Fast.** Powered by the Apple Neural Engine; a sentence transcribes in a blink.
- **Invisible until you need it.** A quiet menu bar icon, a small indicator while you speak, nothing else.

## Install

1. Download `Aloud.dmg` from the [latest release](https://github.com/theabecaster/aloud/releases/latest).
2. Drag **Aloud** to Applications and open it.
3. Follow the short setup: allow the microphone, allow accessibility, and let the one-time voice model download (~500 MB). After that, Aloud works fully offline.

Requires macOS 14 (Sonoma) or later on Apple Silicon.

## Use

Hold **right ⌥**, speak, release. Text appears where your cursor is. Press **Esc** while holding to cancel. **Double-press** the key to keep listening hands-free — edit, click around, keep talking — then press **Esc** (or double-press again) to finish.

Aloud tidies as it types — removes "um"s, honors "scratch that", applies your personal word fixes — at a clean-up level you choose in Settings (or turn it off for word-for-word). The exact words you said are always kept in History, so nothing is ever silently rewritten. Settings also has the hotkey, microphone, launch-at-login, and a **Vocabulary** list for names and terms it should always get right. Everything stays on this Mac.

Aloud updates itself: when a new release is out, an "Update available" item appears in the menu — one click, it swaps itself and relaunches. No background nagging.

## How it works (for the curious)

Speech recognition runs on-device with [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0), converted to CoreML and driven by the [FluidAudio](https://github.com/FluidInference/FluidAudio) SDK (Apache-2.0) on the Apple Neural Engine. The engine is an implementation detail behind a small interface and may change as better on-device models appear.

The only network calls Aloud ever makes: the one-time model download (Hugging Face) and a daily GitHub check for new releases. Nothing is sent, no identifiers, nothing else. Grep the source — it's small.

## Develop

```sh
git clone https://github.com/theabecaster/aloud && cd aloud
swift build && swift test
.build/debug/Aloud --selftest     # headless subsystem checks
bash scripts/make-app.sh          # stage dist/Aloud.app
```

Docs: [architecture](docs/architecture.md) · [testing & evals](docs/testing.md) · [release pipeline](docs/release.md) · [permissions](docs/permissions.md).

Branches: work lands on `dev`; merges to `main` cut a signed, notarized release automatically (version derived from Conventional Commits).

## License

Copyright © 2026 Abraham Gonzalez.

The app source — including all previously published releases — is offered under the [GNU AGPL-3.0](LICENSE): you're free to use, study, modify, and redistribute it, but any derivative — including one offered as a network service — must be released under the AGPL with its full source available.

The speech model weights are licensed separately by their authors (currently CC-BY-4.0 — attribution above).
