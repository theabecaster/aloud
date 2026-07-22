#!/usr/bin/env bash
# Full GUI push-to-talk loop test, no human required (but a real machine with
# permissions granted to BOTH the app and the terminal, plus audible speakers):
#
#   1. Launches the installed app (or an already-running one).
#   2. Opens a fresh TextEdit document and focuses it.
#   3. Posts a synthetic hotkey hold via `Aloud --simulate-hold`, while playing
#      a spoken phrase out of the speakers — the mic hears it, the tap sees the
#      "keypress", the real recorder/transcriber/injector do their jobs.
#   4. Reads the TextEdit document back and asserts the words landed.
#
# This is the highest-fidelity automated check we have: it exercises the exact
# code path a user triggers. Run manually or from a dev loop, not CI.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

APP_BIN="${APP_BIN:-/Applications/Aloud.app/Contents/MacOS/Aloud}"
CLI_BIN="${CLI_BIN:-$APP_BIN}"
PHRASE="the rain in spain stays mainly in the plain"
BUNDLE_ID="com.abrahamgonzalez.aloud"

[ -x "$APP_BIN" ] || { echo "error: $APP_BIN not found — install the app first" >&2; exit 1; }

# LIVE=1 runs the same loop with the live-typing beta enabled; the setting is
# restored afterwards. Requires an app restart to pick up the changed default,
# so we quit any running instance first.
if [ "${LIVE:-0}" = "1" ]; then
  PRIOR_LIVE="$(defaults read "$BUNDLE_ID" liveTyping 2>/dev/null || echo "absent")"
  defaults write "$BUNDLE_ID" liveTyping -bool true
  pkill -f "Aloud.app/Contents/MacOS/Aloud" 2>/dev/null || true
  sleep 1
fi
restore_live() {
  [ "${LIVE:-0}" = "1" ] || return 0
  if [ "$PRIOR_LIVE" = "absent" ]; then
    defaults delete "$BUNDLE_ID" liveTyping 2>/dev/null || true
  else
    defaults write "$BUNDLE_ID" liveTyping -bool "$PRIOR_LIVE"
  fi
}

# 1. App running?
if ! pgrep -qf "Aloud.app/Contents/MacOS/Aloud"; then
  open -a "$(dirname "$(dirname "$(dirname "$APP_BIN")")")"
  sleep 3
fi

# 2. Synthesize the phrase to play through speakers.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; restore_live' EXIT
say -v Samantha -o "$TMP/phrase.aiff" "$PHRASE"
DUR="$(afinfo "$TMP/phrase.aiff" | awk '/estimated duration/ {print $3}')"
HOLD="$(python3 -c "print(float('$DUR') + 1.2)")"

# 3. Focus a fresh TextEdit document (discard any leftovers from prior runs —
# a stale open document makes the readback accumulate across runs).
osascript >/dev/null <<'OSA'
tell application "TextEdit"
  activate
  close every document saving no
  make new document
end tell
OSA
sleep 1

# 4. Hold the hotkey while the phrase plays.
"$CLI_BIN" --simulate-hold "$HOLD" &
HOLD_PID=$!
sleep 0.4
afplay "$TMP/phrase.aiff"
wait "$HOLD_PID"

# 5. Give transcription + injection a moment, then read back.
sleep 6
GOT="$(osascript -e 'tell application "TextEdit" to get text of front document' || echo "")"
osascript -e 'tell application "TextEdit" to close front document saving no' >/dev/null 2>&1 || true

norm() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z ' | tr -s ' '; }
echo "expected: $(norm "$PHRASE")"
echo "got:      $(norm "$GOT")"
if [ -n "$GOT" ] && python3 - "$(norm "$PHRASE")" "$(norm "$GOT")" <<'PY'
import sys
ref, hyp = sys.argv[1].split(), sys.argv[2].split()
d = [[0]*(len(hyp)+1) for _ in range(len(ref)+1)]
for i in range(len(ref)+1): d[i][0] = i
for j in range(len(hyp)+1): d[0][j] = j
for i in range(1, len(ref)+1):
    for j in range(1, len(hyp)+1):
        d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1] + (ref[i-1] != hyp[j-1]))
wer = d[len(ref)][len(hyp)] / max(len(ref), 1)
print(f"WER: {wer:.3f}")
sys.exit(0 if wer <= 0.3 else 1)
PY
then
  echo "loop test PASSED"
else
  echo "loop test FAILED"
  exit 1
fi
