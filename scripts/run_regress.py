#!/usr/bin/env python3
"""Multi-seed regression runner"""
import argparse, concurrent.futures as cf, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ["eth_rand_test", "eth_err_test", "eth_cfg_test", "eth_b2b_test", "eth_bp_test", "eth_corner_test"]

RE_UVM_ERR = re.compile(r"UVM_ERROR\s*:\s*(\d+)")
RE_UVM_FAT = re.compile(r"UVM_FATAL\s*:\s*(\d+)")
RE_SVA = re.compile(r"Assertion failed in \S*?\.(a_\w+)")
RE_SCB = re.compile(r"SCB_SUMMARY\] (.*)")
RE_UVM_MSG = re.compile(r"UVM_(?:ERROR|FATAL) \S+ @ [\d.]+ ?\w*: \S+ \[(\w+)\]")


def run_one(cmd, log, timeout):
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out, rc = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out, rc = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or ""), -9
        out += "\nWATCHDOG_TIMEOUT (wall-clock)"
    Path(log).write_text(out)
    return out, rc, time.time() - t0


def classify(out, rc):
    err = sum(int(x) for x in RE_UVM_ERR.findall(out))
    fat = sum(int(x) for x in RE_UVM_FAT.findall(out))
    sva = RE_SVA.findall(out)
    scb = RE_SCB.search(out)
    detectors = sorted(set(RE_UVM_MSG.findall(out)) | set(sva))
    ok = rc == 0 and err == 0 and fat == 0 and not sva and scb is not None and "WATCHDOG" not in out
    return dict(passed=ok, uvm_error=err, uvm_fatal=fat, sva_fail=len(sva), detectors=detectors,
                summary=scb.group(1) if scb else "")


def verilator_job(exe, test, seed, logdir, timeout):
    log = logdir / f"{test}_s{seed}.log"
    cmd = [str(exe), f"+UVM_TESTNAME={test}", f"+verilator+seed+{seed}", "+verilator+rand+reset+2"]
    out, rc, dt = run_one(cmd, log, timeout)
    r = classify(out, rc)
    r.update(test=test, seed=seed, wall_s=round(dt, 1), log=str(log))
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tests", nargs="*", default=TESTS)
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--seed-base", type=int, default=1)
    ap.add_argument("--build", default=str(ROOT / "build" / "golden"))
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--timeout", type=int, default=900, help="wall-clock seconds per run")
    ap.add_argument("--out", default=None, help="results json (default: <build>/regress.json)")
    a = ap.parse_args()

    build = Path(a.build)
    logdir = build / "logs"
    logdir.mkdir(parents=True, exist_ok=True)
    seeds = range(a.seed_base, a.seed_base + a.seeds)

    exe = build / "sim_exe"
    if not exe.exists():
        sys.exit(f"{exe} missing: run sim/build_verilator.sh {build}")
    # Verilator's randomize() shells out to an SMT solver at runtime; without one every
    # constrained randomize() returns 0 and each run dies on the [RAND] fatal.
    solver = os.environ.get("VERILATOR_SOLVER", "z3 --in").split()[0]
    if not shutil.which(solver):
        sys.exit(f"SMT solver '{solver}' not on PATH (needed by Verilator randomize()). "
                 "Install z3 (apt install z3, or pip install z3-solver) or set VERILATOR_SOLVER.")
    jobs = [(verilator_job, exe, t, s, logdir, a.timeout) for t in a.tests for s in seeds]

    results = []
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        futs = [ex.submit(j[0], *j[1:]) for j in jobs]
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            print(f"{'PASS' if r['passed'] else 'FAIL'} {r['test']:<18} seed={r['seed']:<4} {r['wall_s']:>6}s "
                  f"err={r['uvm_error']} sva={r['sva_fail']} {','.join(r['detectors'])}", flush=True)

    results.sort(key=lambda r: (r["test"], r["seed"]))
    npass = sum(r["passed"] for r in results)
    print(f"\n{npass}/{len(results)} runs passed ({len(set(r['test'] for r in results))} tests x {a.seeds} seeds)")

    Path(a.out or build / "regress.json").write_text(json.dumps(results, indent=1))
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()
