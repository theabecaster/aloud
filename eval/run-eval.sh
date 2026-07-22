#!/usr/bin/env bash
# Model-accuracy eval: transcribe every fixture, score WER, gate on thresholds.
# Fixture audio is synthesized deterministically with `say` (voice+rate pinned
# in the manifest); real recordings can be added alongside. Results land in
# eval/results/report.json. Exit 0 = within thresholds.
#
# Usage: bash eval/run-eval.sh [--bin <path>]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

BIN="${2:-.build/release/Aloud}"
if [ "${1:-}" = "--bin" ]; then BIN="$2"; fi
[ -x "$BIN" ] || { echo "==> building release binary"; swift build -c release; BIN=".build/release/Aloud"; }

MANIFEST="eval/fixtures/manifest.json"
AUDIO_DIR="eval/fixtures/audio"
RESULTS_DIR="eval/results"
mkdir -p "$AUDIO_DIR" "$RESULTS_DIR"

# 1. Generate any missing synthesized fixtures.
python3 - "$MANIFEST" "$AUDIO_DIR" <<'PY'
import json, os, subprocess, sys
manifest, audio_dir = sys.argv[1], sys.argv[2]
with open(manifest) as f:
    data = json.load(f)
for fx in data["fixtures"]:
    synth = fx.get("synth")
    if not synth:
        continue
    out = os.path.join(audio_dir, fx["id"] + ".aiff")
    if os.path.exists(out):
        continue
    subprocess.run(["say", "-v", synth["voice"], "-r", str(synth["rate"]), "-o", out, fx["text"]], check=True)
    print(f"synthesized {fx['id']}")
PY

# 2. Transcribe + score.
python3 - "$MANIFEST" "$AUDIO_DIR" "$BIN" "$RESULTS_DIR" <<'PY'
import json, os, re, subprocess, sys

manifest, audio_dir, bin_path, results_dir = sys.argv[1:5]

def normalize(s):
    s = s.lower()
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    return " ".join(s.split())

def wer(ref, hyp):
    r, h = ref.split(), hyp.split()
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1): d[i][0] = i
    for j in range(len(h) + 1): d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1,
                          d[i-1][j-1] + (r[i-1] != h[j-1]))
    return d[len(r)][len(h)] / max(len(r), 1)

with open(manifest) as f:
    fixtures = json.load(f)["fixtures"]
with open("eval/thresholds.json") as f:
    thresholds = json.load(f)

results, failed = [], False
for fx in fixtures:
    ext = ".aiff" if fx.get("synth") else ".wav"
    audio = os.path.join(audio_dir, fx["id"] + ext)
    if not os.path.exists(audio):
        print(f"skip {fx['id']}: no audio file")
        continue
    proc = subprocess.run([bin_path, "--transcribe", audio],
                          capture_output=True, text=True, timeout=600)
    hyp = proc.stdout.strip()
    score = wer(normalize(fx["text"]), normalize(hyp))
    over = score > thresholds["per_fixture_wer_max"]
    failed |= over
    results.append({"id": fx["id"], "wer": round(score, 4),
                    "ref": fx["text"], "hyp": hyp})
    print(f"{'FAIL' if over else 'ok  '} {fx['id']}: WER={score:.3f}")
    if over:
        print(f"     ref: {normalize(fx['text'])}")
        print(f"     hyp: {normalize(hyp)}")

if not results:
    print("no fixtures were scored")
    sys.exit(1)

avg = sum(r["wer"] for r in results) / len(results)
report = {"average_wer": round(avg, 4), "fixtures": results,
          "thresholds": thresholds}
with open(os.path.join(results_dir, "report.json"), "w") as f:
    json.dump(report, f, indent=2)

print(f"\naverage WER: {avg:.3f} (max {thresholds['average_wer_max']})")
if avg > thresholds["average_wer_max"]:
    print("FAIL: average WER above threshold")
    failed = True
sys.exit(1 if failed else 0)
PY
