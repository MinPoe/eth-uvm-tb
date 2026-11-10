`uvm_analysis_imp_decl(_raw)
`uvm_analysis_imp_decl(_reg)

// Reference model: predicts what the DUT must do for every frame seen on the line,
// tracking config from the register monitor, written based on specs
class eth_refmodel extends uvm_component;
  `uvm_component_utils(eth_refmodel)
  uvm_analysis_imp_raw #(eth_raw,  eth_refmodel) raw_imp;
  uvm_analysis_imp_reg #(reg_item, eth_refmodel) reg_imp;
  uvm_analysis_port    #(eth_exp)                exp_ap;
  eth_cfg cfg;

  // modelled DUT state
  bit          enable = 0, drop_on_error = 1;
  int unsigned max_len = 1518;
  int unsigned n_good, n_crc, n_runt, n_over;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    byte unsigned v[$];
    string        s = "123456789";
    raw_imp = new("raw_imp", this);
    reg_imp = new("reg_imp", this);
    exp_ap  = new("exp_ap", this);
    if (!uvm_config_db#(eth_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("NOCFG", "eth_cfg not set")
    for (int i = 0; i < s.len(); i++) v.push_back(s[i]);
    if (ref_crc32(v) != 32'hCBF4_3926) `uvm_fatal("CRCSELF", "reference CRC32 fails the standard check vector")
  endfunction

  function bit [31:0] expected_reg(bit [2:0] a);
    case (a)
      A_CTRL:   return {30'b0, drop_on_error, enable};
      A_MAXLEN: return max_len;
      A_FRAMES: return n_good;
      A_CRC:    return n_crc;
      A_RUNT:   return n_runt;
      A_OVER:   return n_over;
      default:  return 0;
    endcase
  endfunction

  function void write_reg(reg_item t);
    if (!t.write) return;
    case (t.addr)
      A_CTRL: begin
        enable        = t.wdata[0];
        drop_on_error = t.wdata[1];
      end

      A_MAXLEN: max_len = t.wdata[10:0];

      A_CLR: begin
        n_good = 0;
        n_crc  = 0;
        n_runt = 0;
        n_over = 0;
      end

      default: ;
    endcase
  endfunction

  function void write_raw(eth_raw r);
    eth_exp      e = new("exp");
    int unsigned k = 0;
    byte unsigned body[$];
    byte unsigned msg[$];
    bit [31:0]   fcs, got;
    int unsigned L;

    e.enable        = enable;
    e.drop_on_error = drop_on_error;
    e.max_len       = max_len;
    e.gap           = r.gap;
    e.bp            = cfg.bp_mode;

    while (k < r.bytes.size() && r.bytes[k] == 8'h55) k++;
    if (!enable) begin
      e.outcome  = OUT_DISABLED;
      e.body_len = (k < r.bytes.size() && r.bytes[k] == 8'hD5) ? r.bytes.size() - k - 1 : 0;
    end

    else if (k == 0 || k >= r.bytes.size() || r.bytes[k] != 8'hD5) begin
      e.outcome = OUT_IGNORED;
    end

    else begin
      for (int i = k + 1; i < r.bytes.size(); i++) body.push_back(r.bytes[i]);
      L = body.size();
      e.body_len = L;
      if (L < 64) begin
        e.outcome = OUT_RUNT;
        n_runt++;
      end

      else if (L > max_len) begin
        e.outcome = OUT_OVER;
        n_over++;
      end

      else begin
        for (int i = 0; i < L - 4; i++) msg.push_back(body[i]);
        fcs = ref_crc32(msg);
        got = {body[L-1], body[L-2], body[L-3], body[L-4]};
        if (fcs == got) begin
          e.outcome = OUT_GOOD;
          n_good++;
        end

        else begin
          e.outcome = OUT_CRC;
          n_crc++;
        end
      end

      if (e.outcome == OUT_GOOD || (e.outcome == OUT_CRC && !drop_on_error)) begin
        e.forward = 1;
        e.user    = (e.outcome == OUT_CRC);
        for (int i = 14; i < L - 4; i++) e.payload.push_back(body[i]);
      end
    end
    exp_ap.write(e);
  endfunction
endclass
