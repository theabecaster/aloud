# Roadmap

Planned work, in order. Items graduate from here into issues/PRs.

## Next

0. **Icon color: blue, not blue-violet.** Regenerate `AppIcon.icns` with a true-blue gradient (make-icon.sh). Ships as its own patch release immediately after v0.2.0.
1. **"Concise" clean-up level (AI rewrite, fully on-device).** A fourth level above Standard: rewrites the utterance into a tighter version of the same idea (what Wispr Flow's cloud LLM pass does). Constraint: must run on-device with zero network — candidate is Apple's Foundation Models framework (macOS 26+, Apple Intelligence hardware), gated with `#available` so older systems simply don't show the option. The raw transcript stays in History regardless. Nice-to-have, not required for parity — Off/Light/Standard cover the must-have modes.
2. **Auto-learn vocabulary.** Watch post-dictation corrections (clipboard diffs are too invasive — likely an explicit "fix this" affordance in History) and suggest Replacement entries.
3. **Draggable indicator with position persistence**, and a mic/language quick menu on right-click (Wispr Flow-bar parity).
4. **Custom-vocab ASR biasing.** FluidAudio exposes CTC keyword boosting (`ctcDetectedTerms`); wire the Vocabulary list into recognition itself, not just post-processing.

## Later / maybe

- Multilingual UI + language picker (the model is 25-language; UI is English-first today).
- Streaming partial results in the indicator (FluidAudio `SlidingWindowAsrManager`).
- Snippets (spoken trigger → canned text).
