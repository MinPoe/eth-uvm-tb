`uvm_analysis_imp_decl(_exp)
`uvm_analysis_imp_decl(_axis)
`uvm_analysis_imp_decl(_flag)
`uvm_analysis_imp_decl(_sreg)

// Scoreboard:
//  every frame the model says must be forwarded appears on AXI-Stream, in order, bit-exact,
//    with the right tuser; frames may only be missing if the overflow counter says so
//  no frame is duplicated or invented
//  status pulses (crc_err/runt/oversize) match the model, one pulse per erroneous frame
//  every register read matches the model (counters, config, reset values)
class eth_scb extends uvm_component;
  `uvm_component_utils(eth_scb)
  uvm_analysis_imp_exp  #(eth_exp,    eth_scb) exp_imp;
  uvm_analysis_imp_axis #(axis_frame, eth_scb) axis_imp;
  uvm_analysis_imp_flag #(flag_item,  eth_scb) flag_imp;
  uvm_analysis_imp_sreg #(reg_item,   eth_scb) reg_imp;
  eth_refmodel model;

  eth_exp      fwd_q[$];
  outcome_e    flag_q[$];
  int unsigned lost_since_clr;
  int unsigned n_frames, n_fwd_exp, n_fwd_seen, n_lost, n_flags, n_reg_reads, n_mismatch;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    exp_imp  = new("exp_imp", this);
    axis_imp = new("axis_imp", this);
    flag_imp = new("flag_imp", this);
    reg_imp  = new("reg_imp", this);
  endfunction

  function void write_exp(eth_exp e);
    n_frames++;
    if (e.outcome == OUT_CRC || e.outcome == OUT_RUNT || e.outcome == OUT_OVER) flag_q.push_back(e.outcome);
    if (e.forward) begin
      fwd_q.push_back(e);
      n_fwd_exp++;
    end
  endfunction

  function bit same(eth_exp e, axis_frame f);
    if (e.payload.size() != f.data.size() || e.user != f.user) return 0;
    foreach (e.payload[i]) if (e.payload[i] != f.data[i]) return 0;
    return 1;
  endfunction

  function void write_axis(axis_frame f);
    int hit = -1;
    n_fwd_seen++;
    foreach (fwd_q[i]) if (same(fwd_q[i], f)) begin
      hit = i;
      break;
    end
    if (hit < 0) begin
      n_mismatch++;
      if (fwd_q.size() == 0)
        `uvm_error("SCB", $sformatf("unexpected output frame (len=%0d user=%0b): nothing expected", f.data.size(), f.user))
      else begin
        eth_exp h = fwd_q.pop_front();
        string  why = $sformatf("exp len=%0d user=%0b, got len=%0d user=%0b", h.payload.size(), h.user, f.data.size(), f.user);
        foreach (h.payload[i]) if (i < f.data.size() && h.payload[i] != f.data[i]) begin
          why = {why, $sformatf(" first diff at byte %0d (exp %02x got %02x)", i, h.payload[i], f.data[i])};
          break;
        end
        `uvm_error("SCB", {"output frame does not match any expected frame: ", why})
      end
    end

    else begin
      repeat (hit) begin
        void'(fwd_q.pop_front());
        n_lost++;
        lost_since_clr++;
      end
      void'(fwd_q.pop_front());
    end
  endfunction

  function void write_flag(flag_item f);
    n_flags++;
    if (flag_q.size() == 0) begin
      `uvm_error("FLAG", $sformatf("unexpected %s pulse", f.kind.name()))
    end

    else begin
      outcome_e want = flag_q.pop_front();
      if (want != f.kind) `uvm_error("FLAG", $sformatf("flag mismatch: expected %s got %s", want.name(), f.kind.name()))
    end
  endfunction

  function void write_sreg(reg_item t);
    bit [31:0] want;
    if (t.write) begin
      if (t.addr == A_CLR) begin
        lost_since_clr = 0;
        fwd_q.delete();
      end
      return;
    end
    n_reg_reads++;
    if (t.addr == A_OVFL) begin
      // reads happen at quiescent points: whatever is still queued was never delivered
      repeat (fwd_q.size()) begin
        void'(fwd_q.pop_front());
        n_lost++;
        lost_since_clr++;
      end
      want = lost_since_clr;
    end

    else begin
      want = model.expected_reg(t.addr);
    end
    if (t.rdata != want)
      `uvm_error("REG", $sformatf("read of addr %0d: expected 0x%08x got 0x%08x", t.addr, want, t.rdata))
  endfunction

  function void check_phase(uvm_phase phase);
    if (fwd_q.size() != 0)
      `uvm_error("SCB", $sformatf("%0d expected frame(s) never delivered and overflow counter not read", fwd_q.size()))
    if (flag_q.size() != 0)
      `uvm_error("FLAG", $sformatf("%0d expected status pulse(s) never seen", flag_q.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SCB_SUMMARY", $sformatf("frames_on_line=%0d expected_fwd=%0d delivered=%0d lost(overflow)=%0d flags=%0d reg_reads=%0d mismatches=%0d",
              n_frames, n_fwd_exp, n_fwd_seen, n_lost, n_flags, n_reg_reads, n_mismatch), UVM_NONE)
  endfunction
endclass
