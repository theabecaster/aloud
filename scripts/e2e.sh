#!/usr/bin/env bash
# End-to-end verification on a real machine (not CI — needs TCC grants + model).
#
#   1. Synthesize known phrases with `say`, transcribe via the app binary,
#      assert word error rate.
#   2. Verify --inject actually lands text in TextEdit (AppleScript readback).
#
# Usage: bash scripts/e2e.sh [--skip-inject]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

BIN=".build/release/Aloud"
[ -x "$BIN" ] || { echo "==> building"; swift build -c release; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. transcription accuracy -------------------------------------------------
declare -a PHRASES=(
  "the quick brown fox jumps over the lazy dog"
  "please schedule a meeting for tomorrow at three in the afternoon"
  "dictation should feel effortless and stay private on this machine"
)

normalize() {  # lowercase, strip punctuation, squeeze spaces
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9 \n' | tr -s ' ' | sed 's/^ //; s/ $//'
}

fail=0
i=0
for phrase in "${PHRASES[@]}"; do
  i=$((i + 1))
  aiff="$TMP/p$i.aiff"
  say -o "$aiff" "$phrase"
  got="$("$BIN" --transcribe "$aiff" 2>/dev/null)"
  ref_n="$(normalize "$phrase")"
  got_n="$(normalize "$got")"
  # word-level error rate via python (stdlib only)
  wer="$(python3 - "$ref_n" "$got_n" <<'PY'
import sys
ref, hyp = sys.argv[1].split(), sys.argv[2].split()
d = [[0]*(len(hyp)+1) for _ in range(len(ref)+1)]
for i in range(len(ref)+1): d[i][0] = i
for j in range(len(hyp)+1): d[0][j] = j
for i in range(1, len(ref)+1):
    for j in range(1, len(hyp)+1):
        d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1] + (ref[i-1] != hyp[j-1]))
print(f"{d[len(ref)][len(hyp)] / max(len(ref),1):.3f}")
PY
)"
  echo "phrase $i: WER=$wer"
  echo "  ref: $ref_n"
  echo "  got: $got_n"
  # `say` audio is clean; anything above 20% means the pipeline is broken.
  if python3 -c "import sys; sys.exit(0 if float('$wer') <= 0.20 else 1)"; then
    echo "  ok"
  else
    echo "  FAIL (WER > 0.20)"
    fail=1
  fi
done

# --- 2. injection --------------------------------------------------------------
if [ "${1:-}" != "--skip-inject" ]; then
  echo "==> injection test (TextEdit)"
  MARKER="aloud e2e $(date +%s)"
  osascript <<OSA
tell application "TextEdit"
  activate
  make new document
end tell
OSA
  sleep 1
  "$BIN" --inject "$MARKER"
  sleep 1
  GOT="$(osascript -e 'tell application "TextEdit" to get text of front document' || echo "")"
  osascript -e 'tell application "TextEdit" to close front document saving no' >/dev/null 2>&1 || true
  if [ "$GOT" = "$MARKER" ]; then
    echo "  ok — injected text landed in TextEdit"
  else
    echo "  FAIL — expected '$MARKER', got '$GOT'"
    fail=1
  fi
fi

[ "$fail" = 0 ] && echo "e2e passed" || echo "e2e FAILED"
exit "$fail"
