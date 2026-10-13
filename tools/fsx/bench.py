"""p50 latency over a fixed query set via fsx stdio. Run: fsx-bench (cold cache) -- see README."""
import json, statistics, subprocess, sys, os, tempfile
QS = ["where do we decide model routing", "invoice pdf from september", "what did we decide about turbopuffer",
      "function that parses the config file", "ROUTING-STRATEGY", "how does the dispatcher pick a worker",
      "notes about the fsearch daemon", "where is the typesafe client", "release notes for findersearch", "agent rules for browsers"]
here = os.path.dirname(os.path.abspath(__file__))
def run(typesafe):
    env = dict(os.environ, FSX_CACHE_DIR=tempfile.mkdtemp(), FSX_ESTATE=os.environ.get("FSX_ESTATE", "0"))
    p = subprocess.Popen([os.path.join(here, "fsx"), "stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    ms, calls = [], []
    for q in QS:
        p.stdin.write(json.dumps({"q": q, "typesafe": typesafe}) + "\n"); p.stdin.flush()
        r = json.loads(p.stdout.readline()); ms.append(r["ms"]); calls.append(r["typesafe_calls"])
    p.stdin.close(); p.wait()
    return statistics.median(ms), sum(calls) / len(calls), sorted(ms)
for ts in (False, True):
    p50, c, ms = run(ts)
    print(f"typesafe={ts}: p50 {p50:.0f} ms, calls/query {c:.1f}, all {ms}")
