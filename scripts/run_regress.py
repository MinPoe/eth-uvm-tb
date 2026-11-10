#!/usr/bin/env python3
"""Multi-seed regression runner"""
import argparse, concurrent.futures as cf, json, os, re, subprocess, sys, time
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


def questa_job(workdir, test, seed, logdir, timeout):
    # UNTESTED in the authoring environment (no commercial simulator available).
    log = logdir / f"{test}_s{seed}.log"
    ucdb = workdir / f"cov_{test}_s{seed}.ucdb"
    cmd = ["vsim", "-c", "-lib", str(workdir / "work"), "tb_top", "-coverage", f"-sv_seed", str(seed),
           f"+UVM_TESTNAME={test}", "-do", f"coverage save -onexit {ucdb}; run -all; quit -f"]
    out, rc, dt = run_one(cmd, log, timeout)
    r = classify(out, rc)
    r.update(test=test, seed=seed, wall_s=round(dt, 1), log=str(log), ucdb=str(ucdb))
    return r


def questa_build(workdir, uvm_src):
    workdir.mkdir(parents=True, exist_ok=True)
    srcs = [ROOT / "rtl" / f for f in ("eth_regs.sv", "eth_rx.sv", "eth_top.sv")] + \
           [ROOT / "tb" / f for f in ("eth_ifs.sv", "eth_pkg.sv", "tb_top.sv")]
    subprocess.run(["vlib", str(workdir / "work")], check=True)
    subprocess.run(["vlog", "-sv", "-work", str(workdir / "work"), "-cover", "bcesf", "+cover=bcesf",
                    f"+incdir+{ROOT/'tb'}"] + [str(s) for s in srcs], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", choices=["verilator", "questa"], default="verilator")
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

    if a.sim == "verilator":
        exe = build / "sim_exe"
        if not exe.exists():
            sys.exit(f"{exe} missing: run sim/build_verilator.sh {build}")
        jobs = [(verilator_job, exe, t, s, logdir, a.timeout) for t in a.tests for s in seeds]
    else:
        questa_build(build, os.environ["UVM_SRC"])
        jobs = [(questa_job, build, t, s, logdir, a.timeout) for t in a.tests for s in seeds]

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

    if a.sim == "questa":
        ucdbs = [r["ucdb"] for r in results if Path(r["ucdb"]).exists()]
        merged = build / "merged.ucdb"
        subprocess.run(["vcover", "merge", "-out", str(merged)] + ucdbs, check=True)
        subprocess.run(["vcover", "report", "-details", "-cvg", "-output", str(build / "coverage.txt"), str(merged)], check=True)
        print(f"merged coverage: {merged}  report: {build/'coverage.txt'}")

    Path(a.out or build / "regress.json").write_text(json.dumps(results, indent=1))
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()
