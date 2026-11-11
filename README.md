# UVM verification of an Ethernet frame RX block

SystemVerilog/UVM testbench for a small Ethernet-style frame receiver (RX path + config registers), with constrained-random stimulus, a reference model, scoreboard, SVA, a multi-seed regression script, and a 14-bug injection campaign

## Results (measured)

| Metric | Value |
|---|---|
| Tests | 6 (rand, err, cfg, b2b, bp, corner) |
| Assertions | 11 SVA assertions + 2 cover properties |
| Golden regression | 60/60 pass (6 tests x 10 seeds) |
| Bug injection | **14/14 planted bugs caught** (252 runs: 6 tests x 3 seeds x 14 bugs) |
| Functional coverage % | **not measured** - Verilator ignores covergroups; covergroups are written (`tb/eth_cov.svh`) but requires a simulator that I don't have access to in order to collect |


## Design (`rtl/`)

```
 line_valid/line_data --> eth_rx --> AXI-Stream (tdata/tvalid/tready/tlast/tuser)
                           |  |
        reg bus --> eth_regs <- events        outputs: crc_err, runt, oversize, frame_count
```

Line format: `0x55` x N, `0xD5`, then `dst(6) src(6) type(2) payload(pad to 46) FCS(4, LSB first)`; `line_valid` high for the whole frame, >=1 idle cycle between frames

- body < 64 --> runt (dropped); body > `max_len` --> oversize (dropped); CRC32 mismatch --> `crc_err` (dropped, or forwarded with `tuser=1` when `drop_on_error=0`)
- Payload (padding included) is buffered in a 2-entry ping-pong buffer and streamed out. A frame that should be forwarded but finds both buffers full is dropped and counted in OVFL_CNT
- No SFD, or disabled --> frame ignored (no flags/counters)
- Registers (word addr): 0 CTRL (`[0]` enable, `[1]` drop_on_error), 1 MAX_LEN, 2 FRAME_CNT, 3 CRC_CNT, 4 RUNT_CNT, 5 OVER_CNT, 6 OVFL_CNT, 7 CLR
- Bugs are planted with `` `ifdef BUG_<NAME> `` (14 of them)

## Testbench (`tb/`)

```
 tests --> sequences --> line agent (driver) --> DUT --> axis agent (sink, backpressure) --+
              |          reg agent  (driver) -->                                           |
              |                                                                            v
   line monitor -> ref model (independent CRC, config tracked from reg monitor) -> scoreboard <- axis monitor
   reg monitor  ->                         +--------------> coverage                       <- flag monitor
 SVA (eth_ifs.sv: eth_checks) on the DUT pins
```

- Reference model works from what the line monitor actually saw, and uses a textbook MSB-first CRC32 (different formulation from the RTL), self-checked against the `"123456789"` --> `0xCBF43926` vector
- Scoreboard: bit-exact payload/tuser in order; no duplicates; frames may be missing only as counted by OVFL_CNT; status pulses match one-to-one; every register read matches the model
- Backpressure is driven by `eth_cfg.bp_mode` (none / 50% / 10% / bursty), changed by the tests
- Covergroup `cg_frame`: length x outcome, config(drop x enable) x outcome, backpressure x outcome, backpressure x length, gap x outcome

## Running

Requires Verilator >= 5.4x with `--binary --timing` (tested 5.49 from `pip install verilator`) and the Accellera UVM source (tested `uvm-core` 2020.3.1)

Verilator solves `randomize()` constraints by calling an external SMT solver at **runtime**, so `z3` must be on `PATH` (or point `VERILATOR_SOLVER` at another one, e.g. `"cvc5 --incremental"`). Without it every constrained `randomize()` returns 0 and each test dies on `UVM_FATAL [RAND]`; `run_regress.py` checks for this up front. `apt install z3`, or without root:

```
python3 -m venv ~/.local/z3env && ~/.local/z3env/bin/pip install z3-solver
export PATH=$HOME/.local/z3env/bin:$PATH
```

```
sim/build_verilator.sh build/golden            # ~3-4 min
python3 scripts/run_regress.py --seeds 10      # all tests x 10 seeds, pass/fail table
sim/build_verilator.sh build/BUG_CNT8 CNT8     # a bug variant
python3 scripts/bug_campaign.py --seeds 3      # all 14 bugs (~1 h)
```

Verilator notes: UVM runs with `+define+UVM_NO_DPI`; the build script passes `CFG_CXXFLAGS_PCH_I=-include` because the pip wheel ships an empty precompiled-header flag; an SVA failure aborts the run (`$stop`)

## Known limits
- Configuration is never changed while a frame is in flight; `a_no_out_dis` assumes buffers are empty when `enable` falls
- Backpressure and config are set from the test, not randomized per frame