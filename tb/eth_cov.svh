// Functional coverage, sampled once per frame from the reference model's prediction
class eth_cov extends uvm_subscriber #(eth_exp);
  `uvm_component_utils(eth_cov)

  covergroup cg_frame with function sample(outcome_e o, int unsigned blen, bit drop, bit en,
                                           bp_e bp, int unsigned gap);
    cp_out : coverpoint o {
      bins good = {OUT_GOOD};
      bins crc  = {OUT_CRC};
      bins runt = {OUT_RUNT};
      bins over = {OUT_OVER};
      bins ign  = {OUT_IGNORED};
      bins dis  = {OUT_DISABLED};
    }
    cp_len : coverpoint blen {
      bins l_0      = {0};
      bins l_1_17   = {[1:17]};
      bins l_18_62  = {[18:62]};
      bins l_63     = {63};
      bins l_64     = {64};
      bins l_65_127 = {[65:127]};
      bins l_128_1023 = {[128:1023]};
      bins l_1024_1517 = {[1024:1517]};
      bins l_1518   = {1518};
      bins l_over   = {[1519:$]};
    }
    cp_drop : coverpoint drop;
    cp_en   : coverpoint en;
    cp_bp   : coverpoint bp;
    cp_gap  : coverpoint gap {
      bins g1     = {1};
      bins g2_3   = {[2:3]};
      bins g4_16  = {[4:16]};
      bins g_long = {[17:$]};
    }

    // length x error type
    x_len_out : cross cp_len, cp_out {
      ignore_bins ig_valid_len = binsof(cp_out) intersect {OUT_GOOD, OUT_CRC} && binsof(cp_len) intersect {[0:63], [1519:$]};
      ignore_bins ig_runt_len  = binsof(cp_out) intersect {OUT_RUNT} && binsof(cp_len) intersect {[64:$]};
      ignore_bins ig_over_len  = binsof(cp_out) intersect {OUT_OVER} && binsof(cp_len) intersect {[0:63]};
      ignore_bins ig_ign_len   = binsof(cp_out) intersect {OUT_IGNORED} && binsof(cp_len) intersect {[1:$]};
    }
    // config x error type
    x_cfg_out : cross cp_drop, cp_en, cp_out {
      ignore_bins ig_dis_only  = binsof(cp_en) intersect {0} && !binsof(cp_out) intersect {OUT_DISABLED};
      ignore_bins ig_en_no_dis = binsof(cp_en) intersect {1} && binsof(cp_out) intersect {OUT_DISABLED};
    }
    // backpressure x error type, backpressure x length
    x_bp_out : cross cp_bp, cp_out {
      ignore_bins ig_dis = binsof(cp_out) intersect {OUT_DISABLED};
    }
    x_bp_len : cross cp_bp, cp_len;
    // inter-frame gap x error type
    x_gap_out : cross cp_gap, cp_out {
      ignore_bins ig_dis = binsof(cp_out) intersect {OUT_DISABLED};
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_frame = new();
  endfunction

  function void write(eth_exp t);
    cg_frame.sample(t.outcome, t.body_len, t.drop_on_error, t.enable, t.bp, t.gap);
  endfunction

  function void report_phase(uvm_phase phase);
    `ifndef VERILATOR
      `uvm_info("FUNC_COV", $sformatf("cg_frame inst coverage = %0.2f%%", cg_frame.get_inst_coverage()), UVM_NONE)
    `endif
  endfunction
endclass
