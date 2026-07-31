#!/usr/bin/env bash
# Agent Speak end-to-end check: a real app process, a real Unix socket, the real
# CLI, one assertion at a time.
#
# Every serious bug on this branch was invisible to the unit suite and only
# showed up when the shipped binary talked to a shipped socket: leases reaped
# instantly because liveness keyed on the CLI's own pid, a bridge that failed to
# start with an unreadable error, a queue wait that spun forever because a
# real-time sleep was bounded by a logical clock. Those are the shapes this
# script exists to catch, so it does everything across separate process
# invocations and in real wall-clock time — never in one address space.
#
# WHAT IT COVERS
#   * The app launches into an isolated state dir + defaults suite (nothing here
#     touches the real settings, the installed app, or the developer's history).
#   * The socket path fits sockaddr_un's 104 bytes, checked before anything else.
#   * The gate: experiment off => no socket file exists at all, and the CLI says
#     `disabled` (not `unavailable`) because the app is up.
#   * The gate is read at launch: an external `defaults write` does NOT reach a
#     running app, and a relaunch does.
#   * The bridge actually started — the app log must not carry a start failure.
#   * A full session in consent mode `open`: claim -> speak -> (pause) -> speak
#     on the SAME lease from a SEPARATE process -> release. The second speak is
#     the lease-reaping regression test.
#   * Contention: a second harness claiming while the first holds gets `queued`
#     with `queuedBehind` naming the holder.
#   * The parked wait: `claim --wait N` in the background is still parked a
#     moment later and is granted once the holder releases (real seconds, real
#     cooldown).
#   * Refusal shapes: bogus lease -> `notHolder` (for speak AND listen), speak
#     with no lease -> usage error, exit 64, and every verb with the app not
#     running -> `unavailable`, exit 1.
#   * Every response is valid JSON, parsed with python3 rather than grepped.
#
# WHAT IT DELIBERATELY DOES NOT COVER
#   * `listen` with real speech. There is no microphone grant for a bare
#     `swift build` binary and a real listen would block on an endpoint that
#     never arrives. Only listen's REFUSAL path (bogus lease, no lease, app
#     down) is exercised — all of which return before any audio starts. Capture,
#     endpointing and transcript delivery are NOT tested here; scripts/e2e.sh
#     and scripts/loop-test.sh are the microphone tests.
#   * Consent modes 2 and 3 (confirm on screen / confirm by voice). Both need a
#     human to answer, so this runs entirely in mode `open`.
#   * The indicator, the menu bar, the harness installers, and onboarding.
#   * Anything about *what* `speak` says. It asserts the call succeeded, not
#     that the audio was intelligible — note that it really does talk out loud.
#
# Usage: bash scripts/agent-speak-check.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

BIN=".build/debug/Aloud"
[ -x "$BIN" ] || { echo "==> building"; swift build; }
BIN="$DIR/$BIN"

# The app launches into full dictation startup, which includes preparing the
# speech model. If it isn't on disk that is a ~460 MB download kicked off by a
# test — fail here with the fix instead.
MODELS="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
if [ ! -d "$MODELS" ]; then
  cat >&2 <<MSG
error: the speech model isn't downloaded, and launching the app would start a
       ~460 MB fetch as a side effect of this test. Run Aloud once and let it
       finish setup first, then re-run this script.
       (looked for: $MODELS)
MSG
  exit 1
fi

# --- isolation ---------------------------------------------------------------
# Short on purpose. The bridge socket lives inside the state dir and
# sockaddr_un.sun_path is a fixed 104-byte field: a $TMPDIR path (which on macOS
# is /var/folders/xx/……/T/) blows straight past it, and the failure is a bridge
# that silently never comes up. Asserted below rather than trusted.
STATE="/tmp/aloud-agent-check.$$"
SUITE="com.abrahamgonzalez.aloud.agentcheck.$$"
SOCK="$STATE/bridge.sock"
APPLOG="$STATE/app.log"
ERRLOG="$STATE/cli.err"
APP_PID=""
WAIT_PID=""

PASSES=0
FAILURES=0

cleanup() {
  [ -n "$WAIT_PID" ] && kill "$WAIT_PID" 2>/dev/null || true
  stop_app
  # `defaults delete` empties the domain but leaves an empty plist behind, and
  # a test that litters ~/Library/Preferences one file per run is its own small
  # bug. Remove both, in that order — deleting the file first would let cfprefsd
  # write its cached copy back out.
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
  rm -rf "$STATE"
  return 0
}

pass() { PASSES=$((PASSES + 1)); printf 'PASS  %s\n' "$1"; }

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '        %s\n' "$2"
  return 0
}

expect_eq() {  # label, expected, actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# --- driving the CLI ---------------------------------------------------------

# Every CLI call is its own process with the same isolation env — which is the
# whole point: a lease that only survives inside one process proves nothing.
run_cli() {
  set +e
  LAST_OUT="$(ALOUD_STATE_DIR="$STATE" ALOUD_DEFAULTS_SUITE="$SUITE" "$BIN" "$@" 2>"$ERRLOG")"
  LAST_RC=$?
  set -e
}

# Pull one field out of the last response. python3, not grep: "reason":"queued"
# and a message that happens to contain the word queued are different things.
field() {  # field name -> value, or "" when absent / not JSON
  printf '%s' "$LAST_OUT" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
value = doc.get(sys.argv[1])
if value is None:
    pass
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, str):
    print(value)
else:
    print(json.dumps(value))
' "$1"
}

is_json() { printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }

# --- app lifecycle -----------------------------------------------------------

start_app() {
  ALOUD_STATE_DIR="$STATE" ALOUD_DEFAULTS_SUITE="$SUITE" "$BIN" >>"$APPLOG" 2>&1 &
  APP_PID=$!
  # Ready = the CLI can reach it at all. `unavailable` is synthesised by the
  # client when nothing holds the singleton lock, so anything else means the
  # app is up — including `disabled`, which is exactly the state phase 1 wants.
  local waited=0
  while [ "$waited" -lt 300 ]; do
    run_cli status
    [ "$(field reason)" != "unavailable" ] && return 0
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      echo "error: the app exited during startup — log follows" >&2
      cat "$APPLOG" >&2
      exit 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  echo "error: the app never became reachable in 30 s — log follows" >&2
  cat "$APPLOG" >&2
  exit 1
}

stop_app() {
  [ -n "$APP_PID" ] || return 0
  # `wait` reports the signal that killed it (143), which is the expected
  # outcome here — swallowed rather than allowed to trip `set -e`.
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  # The CLI decides "not running" from the singleton lock, which the kernel
  # drops when the process dies — but only once it is really gone.
  local waited=0
  while [ "$waited" -lt 100 ]; do
    run_cli status
    [ "$(field reason)" = "unavailable" ] && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

mkdir -p "$STATE"
trap cleanup EXIT

echo "state dir:      $STATE"
echo "defaults suite: $SUITE"
echo

# --- 0. the 104-byte field ---------------------------------------------------
echo "== socket path"
if [ "${#SOCK}" -lt 104 ]; then
  pass "socket path is ${#SOCK} bytes, under sockaddr_un's 104-byte sun_path"
else
  fail "socket path fits sockaddr_un" \
       "${#SOCK} bytes: $SOCK — bind() truncates silently and the bridge never comes up. Use a shorter state dir."
fi
echo

# Onboarding done (so no walkthrough window opens), consent `open` (so nothing
# waits on a human), gate still off — phase 1 is about the gate being closed.
defaults write "$SUITE" onboardingComplete -bool true
defaults write "$SUITE" agentConsentMode -string open

# --- 1. the gate is shut -----------------------------------------------------
echo "== gate off"
start_app
if [ -e "$SOCK" ]; then
  fail "no socket file exists while the experiment is off" "found $SOCK"
else
  pass "no socket file exists while the experiment is off"
fi

run_cli status
expect_eq "status with the gate off says 'disabled', not 'unavailable'" "disabled" "$(field reason)"
expect_eq "  ...and exits 0 (a refusal is an answer, not a failed command)" "0" "$LAST_RC"

run_cli claim --harness claude-code --name "check run"
expect_eq "claim with the gate off is refused with 'disabled'" "disabled" "$(field reason)"

# The gate is read once, at launch. A `defaults write` from out here lands in
# the plist but cannot reach a process that already read it — so the script has
# to relaunch, and this asserts that rather than assuming it.
defaults write "$SUITE" experimentalAgentVoice -bool true
sleep 1
run_cli status
expect_eq "an external 'defaults write' does not reach the running app" "disabled" "$(field reason)"
echo

# --- 2. the gate is open -----------------------------------------------------
echo "== gate on (after relaunch)"
stop_app
start_app

if [ -S "$SOCK" ]; then
  pass "the socket exists once the experiment is on"
else
  fail "the socket exists once the experiment is on" "no socket at $SOCK"
fi

MODE="$(stat -f '%OLp' "$SOCK" 2>/dev/null || echo "?")"
expect_eq "the socket is 0600" "600" "$MODE"

# The bridge failing to start used to be a line on stderr nobody read, and every
# later assertion would blame the wrong thing.
if grep -q "agent bridge failed to start" "$APPLOG"; then
  fail "the bridge started cleanly" "$(grep 'agent bridge failed to start' "$APPLOG" | tail -1)"
else
  pass "the bridge started cleanly (no start failure in the app log)"
fi

run_cli status
if is_json "$LAST_OUT"; then pass "status returns valid JSON"; else fail "status returns valid JSON" "$LAST_OUT"; fi
expect_eq "status reports the feature enabled" "true" "$(field enabled)"
echo

# --- 3. a full session -------------------------------------------------------
echo "== session: claim -> speak -> speak -> release"
run_cli claim --harness claude-code --name "check run"
LEASE="$(field lease)"
expect_eq "claim is granted" "true" "$(field ok)"
if [ -n "$LEASE" ]; then pass "claim returns a lease id ($LEASE)"; else fail "claim returns a lease id" "$LAST_OUT"; fi

run_cli status
expect_eq "status names the holder while the lease is out" "claude-code" "$(field holder)"

run_cli speak --lease "$LEASE" "Agent check, first line."
expect_eq "speak on the lease succeeds" "true" "$(field ok)"

# THE regression: a lease has to survive between two separate CLI processes,
# seconds apart. Keying liveness on the socket peer's pid made this call fail
# with notHolder every single time, and no unit test noticed.
sleep 6
run_cli speak --lease "$LEASE" "Agent check, second line, same lease."
if [ "$(field ok)" = "true" ]; then
  pass "the SAME lease still works 6 s later from a separate process"
else
  fail "the SAME lease still works 6 s later from a separate process" \
       "reason=$(field reason) — a lease must outlive the connection that created it"
fi

run_cli release --lease "$LEASE"
expect_eq "release succeeds" "true" "$(field ok)"
echo

# --- 4. contention -----------------------------------------------------------
echo "== contention"
# --wait rides out the post-release cooldown instead of racing it.
run_cli claim --harness claude-code --name "check run" --wait 10
LEASE="$(field lease)"
expect_eq "claim --wait rides out the cooldown and is granted" "true" "$(field ok)"

run_cli claim --harness codex --name "check run"
expect_eq "a second harness is refused with 'queued'" "queued" "$(field reason)"
expect_eq "  ...and 'queuedBehind' names the holder" "claude-code" "$(field queuedBehind)"
expect_eq "  ...and reports a queue position" "1" "$(field position)"

# The ceiling has to be reachable in real seconds. A wait loop whose sleep is
# real but whose deadline is a logical clock never gets here — it spins until
# something else kills it, which is how this last broke.
START=$SECONDS
run_cli claim --harness cursor --name "check run" --wait 3
ELAPSED=$((SECONDS - START))
expect_eq "a --wait that runs out its ceiling comes back 'queued'" "queued" "$(field reason)"
if [ "$ELAPSED" -ge 2 ] && [ "$ELAPSED" -le 15 ]; then
  pass "  ...after about its ceiling, not instantly and not forever (${ELAPSED}s for --wait 3)"
else
  fail "  ...after about its ceiling, not instantly and not forever" \
       "--wait 3 took ${ELAPSED}s"
fi
echo

# --- 5. the parked wait ------------------------------------------------------
echo "== parked wait"
# Backgrounded on purpose: an agent parks this in a shell and the command exits
# when the microphone is its turn. The CLI writes nothing until it resolves, so
# an empty file IS "still parked".
WAITOUT="$STATE/parked.json"
: > "$WAITOUT"
ALOUD_STATE_DIR="$STATE" ALOUD_DEFAULTS_SUITE="$SUITE" \
  "$BIN" claim --harness codex --wait 60 --name "check run" >"$WAITOUT" 2>/dev/null &
WAIT_PID=$!

sleep 3
if [ -s "$WAITOUT" ]; then
  fail "'claim --wait' is still parked while another harness holds the lease" \
       "it returned early: $(cat "$WAITOUT")"
else
  pass "'claim --wait' is still parked 3 s in, while another harness holds the lease"
fi

run_cli release --lease "$LEASE"
expect_eq "the holder releases" "true" "$(field ok)"

# Cooldown is 1.5 s and the wait polls every 0.25 s; 20 s is slack, not a
# guess. If this hangs, the wait loop is spinning on a clock that never moves.
waited=0
while [ ! -s "$WAITOUT" ] && [ "$waited" -lt 200 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
wait "$WAIT_PID" 2>/dev/null || true
WAIT_PID=""

LAST_OUT="$(cat "$WAITOUT")"
if [ "$(field ok)" = "true" ]; then
  pass "the parked claim was granted after the release (took $((waited / 10)) s)"
else
  fail "the parked claim was granted after the release" \
       "got: ${LAST_OUT:-<nothing — it never resolved>}"
fi
QUEUED_LEASE="$(field lease)"
[ -n "$QUEUED_LEASE" ] && run_cli release --lease "$QUEUED_LEASE"
echo

# --- 6. refusals are shaped right --------------------------------------------
echo "== refusals"
run_cli speak --lease L-nope-not-a-lease "This should not be said."
expect_eq "speak with a bogus lease is refused with 'notHolder'" "notHolder" "$(field reason)"
expect_eq "  ...and still exits 0" "0" "$LAST_RC"

# The one thing about `listen` this script can assert without a microphone: it
# refuses a bogus lease before any audio path is touched.
run_cli listen --lease L-nope-not-a-lease
expect_eq "listen with a bogus lease is refused with 'notHolder' (no mic opened)" \
          "notHolder" "$(field reason)"

run_cli speak "text with no lease"
expect_eq "speak with no lease is a usage error, exit 64" "64" "$LAST_RC"
if grep -q "usage:" "$ERRLOG"; then
  pass "  ...and prints usage on stderr"
else
  fail "  ...and prints usage on stderr" "stderr was: $(cat "$ERRLOG")"
fi

run_cli claim
expect_eq "claim with no --harness is a usage error, exit 64" "64" "$LAST_RC"
echo

# --- 7. app not running ------------------------------------------------------
echo "== app not running"
stop_app
for verb in status claim release speak listen; do
  case "$verb" in
    status)  run_cli status ;;
    claim)   run_cli claim --harness claude-code --name "check run" ;;
    release) run_cli release --lease L1 ;;
    speak)   run_cli speak --lease L1 "nobody is home" ;;
    listen)  run_cli listen --lease L1 ;;
  esac
  expect_eq "$verb with the app down is refused with 'unavailable'" "unavailable" "$(field reason)"
  expect_eq "  ...and exits 1" "1" "$LAST_RC"
done
echo

echo "NOTE: 'listen' with real speech is NOT covered here — no microphone grant"
echo "      in this context, and a real capture would block. Only its refusal"
echo "      paths are asserted. See scripts/e2e.sh / scripts/loop-test.sh."
echo
echo "$PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ] || exit 1
echo "agent speak check PASSED"
