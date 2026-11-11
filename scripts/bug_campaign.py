#!/usr/bin/env python3
"""Build each planted-bug variant, run every test x N seeds, record which checks caught it, outputs docs/bug_campaign.json"""
import argparse, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUGS = ["CRC_INIT", "RUNT_LIMIT", "OVER_OFFBY1", "TLAST_MIN", "BP_DROP", "B2B_RACE", "CRC_CNT_COND",
        "DISABLE_LEAK", "MAXLEN_W", "CNT8", "ADDR_WRAP", "RUNT_CRC", "OVFL_NOCNT", "DROP_POL"]

ap = argparse.ArgumentParser()
ap.add_argument("--seeds", type=int, default=3)
ap.add_argument("bugs", nargs="*", default=BUGS)
a = ap.parse_args()

out_json = ROOT / "docs" / "bug_campaign.json"
res = json.loads(out_json.read_text()) if out_json.exists() else {}
for bug in a.bugs:
    bdir = ROOT / "build" / f"BUG_{bug}"
    b = subprocess.run([str(ROOT / "sim" / "build_verilator.sh"), str(bdir), bug], capture_output=True, text=True)
    if b.returncode:
        res[bug] = {"build_failed": b.stdout[-500:] + b.stderr[-500:]}
        print(bug, "BUILD FAILED:", (b.stdout + b.stderr)[-500:], flush=True)
        continue
    rj = bdir / "regress.json"
    rj.unlink(missing_ok=True)  # never read a stale result from an earlier campaign
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "run_regress.py"), "--build", str(bdir),
                        "--seeds", str(a.seeds), "--jobs", "2", "--out", str(rj)],
                       capture_output=True, text=True)
    # run_regress exits 1 whenever a run fails (expected for a planted bug), so judge by its output file
    if not rj.exists():
        sys.exit(f"{bug}: run_regress.py produced no results:\n{r.stdout[-1000:]}{r.stderr[-1000:]}")
    runs = json.loads(rj.read_text())
    # a run that died before the scoreboard summary (e.g. [RAND] fatal) is not a detection
    bogus = [x for x in runs if "RAND" in x["detectors"]]
    if bogus:
        sys.exit(f"{bug}: {len(bogus)} runs died without running (detectors={bogus[0]['detectors']}), see {bogus[0]['log']}")
    by_test = {}
    for x in runs:
        t = by_test.setdefault(x["test"], {"fail": 0, "runs": 0, "detectors": set()})
        t["runs"] += 1
        t["fail"] += (not x["passed"])
        t["detectors"] |= set(x["detectors"])
    res[bug] = {"caught": any(t["fail"] for t in by_test.values()),
                "tests": {k: {"fail": v["fail"], "runs": v["runs"], "detectors": sorted(v["detectors"])}
                          for k, v in by_test.items()}}
    print(bug, "CAUGHT" if res[bug]["caught"] else "MISSED", flush=True)
    out_json.parent.mkdir(exist_ok=True)
    out_json.write_text(json.dumps(res, indent=1))
