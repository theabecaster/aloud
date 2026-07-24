#!/usr/bin/env python3
"""Run the shared fixtures through a llama-server instance, capture outputs + timings."""
import json, sys, time, subprocess, urllib.request, os, signal

EVAL_DIR = os.path.dirname(os.path.abspath(__file__))
PORT = 18080

def post(path, body):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)

def wait_ready(proc, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError("llama-server exited early")
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2)
            return
        except Exception:
            time.sleep(0.5)
    raise RuntimeError("server never became ready")

def main():
    model_path, out_name = sys.argv[1], sys.argv[2]
    prompts_file = sys.argv[3] if len(sys.argv) > 3 else "prompts.json"
    fixtures = json.load(open(f"{EVAL_DIR}/fixtures.json"))
    prompts = json.load(open(f"{EVAL_DIR}/{prompts_file}"))

    t_load0 = time.time()
    proc = subprocess.Popen(
        ["llama-server", "-m", model_path, "--port", str(PORT),
         "-ngl", "99", "-c", "4096", "--no-webui"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_ready(proc)
        load_ms = (time.time() - t_load0) * 1000

        # warmup
        post("/v1/chat/completions", {"messages": [
            {"role": "system", "content": prompts["cleanup"]},
            {"role": "user", "content": "Um hello there."}],
            "temperature": 0.1, "max_tokens": 64})

        results = []
        for f in fixtures:
            body = {"messages": [
                {"role": "system", "content": prompts[f["task"]]},
                {"role": "user", "content": f["transcript"]}],
                "temperature": 0.1, "max_tokens": 512, "timings_per_token": False}
            t0 = time.time()
            resp = post("/v1/chat/completions", body)
            total_ms = (time.time() - t0) * 1000
            timings = resp.get("timings", {})
            out = resp["choices"][0]["message"]["content"].strip()
            results.append({
                "id": f["id"], "task": f["task"], "transcript": f["transcript"],
                "output": out, "totalMs": total_ms,
                "promptMs": timings.get("prompt_ms"),
                "predictedMs": timings.get("predicted_ms"),
                "promptTps": timings.get("prompt_per_second"),
                "genTps": timings.get("predicted_per_second"),
                "genTokens": timings.get("predicted_n"),
            })
            print(f"{f['id']}: {int(total_ms)}ms (gen {timings.get('predicted_n')} tok @ {round(timings.get('predicted_per_second') or 0)} t/s)", file=sys.stderr)

        json.dump({"loadMs": load_ms, "results": results},
                  open(f"{EVAL_DIR}/{out_name}", "w"), indent=1)
        print(f"wrote {out_name} (model load {int(load_ms)}ms)")
    finally:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=10)

if __name__ == "__main__":
    main()
