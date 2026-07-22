# Testing

Layered so agents can verify everything headlessly. CI runs layers 1–3 on every PR; layer 4 (evals) runs on PRs touching transcription and nightly.

## 1. Unit tests — `swift test`

Pure-logic coverage: hotkey combo encoding/decoding, settings round-trip, history store, semver compare in the updater, audio resampling math, pasteboard snapshot model. No permissions, no model, no GUI.

## 2. Self-test — `Aloud --selftest`

In-process integration checks that need AppKit but no TCC permissions and no model:

- settings + history persistence round-trip in a temp dir
- hotkey event-tap decision logic driven by synthetic `CGEvent`s (hold, short-tap-ignore, Esc-cancel)
- injector pasteboard save/restore (against a private pasteboard, not the general one)
- indicator panel builds and lays out offscreen
- doctor JSON schema stability

Exit code 0 = pass. This is the required CI gate.

## 3. Smoke — CLI paths in CI

```sh
Aloud --version
Aloud --doctor          # JSON: permissions, model presence, settings paths
Aloud --transcribe f.wav  # only where the model is cached (local/e2e), not on PR runners
```

## 4. Evals — `eval/`

Accuracy regression harness for the on-device model. `bash eval/run-eval.sh`:

1. Fixtures: `eval/fixtures/manifest.json` maps audio → reference transcripts. Audio is synthesized deterministically with macOS `say` voices at various rates (generated on demand, gitignored) plus any real recordings added by hand.
2. Runs `Aloud --transcribe` over each fixture.
3. Scores WER/CER per fixture (`eval/wer.swift`), writes `eval/results/report.json`.
4. Gate: fails if average WER exceeds the threshold in `eval/thresholds.json` or any fixture regresses > its per-file bound.

When to run: PRs that touch `Sources/Aloud/Transcription/**` or bump the FluidAudio pin (CI path filter), plus a nightly scheduled run. Model (~an over-a-GB download) is cached between CI runs via `actions/cache`.

`say`-synthesized speech is clean-room audio — good for regression detection (did the pipeline break / model swap change accuracy), not an absolute benchmark. Treat threshold numbers as ratchets, not truth.

## 5. Update pipeline — `Aloud --update-check`

Headless probe of the release feed (current vs latest, whether an update would apply). The actual install path (download → signature+team verify → atomic swap → relaunch) is exercised from the GUI's "Check for Updates…"; test it by installing an older release and updating.

## 6. End-to-end — `scripts/e2e.sh` (local machine only)

Full loop on a real machine with permissions granted: synthesizes a phrase with `say -o`, feeds it through `--transcribe`, asserts WER; then verifies `--inject` lands text in a scratch TextEdit document via AppleScript readback. Not run on CI (needs TCC).

## Clean-account acceptance

Final release check happens in a fresh macOS user account (no permissions pre-granted): onboarding must request mic + accessibility with clear copy, deep-link to the right Settings pane on denial, and the app must be inert-but-alive until granted. Checklist in `docs/release.md`.
