// All drivers act on negedge clk, all monitors sample on posedge clk (keep race-free against the DUT)

// ------------- line agent (RX byte stream) -----------
class line_driver extends uvm_driver #(eth_frame);
  `uvm_component_utils(line_driver)
  virtual line_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual line_if)::get(this, "", "line_vif", vif))
      `uvm_fatal("NOVIF", "line_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    vif.valid = 1'b0;
    vif.data  = 8'h00;
    forever begin
      seq_item_port.get_next_item(req);
      req.build();
      foreach (req.wbytes[i]) begin
        @(negedge vif.clk);
        vif.valid = 1'b1;
        vif.data  = req.wbytes[i];
      end
      repeat (req.ifg) begin
        @(negedge vif.clk);
        vif.valid = 1'b0;
      end
      seq_item_port.item_done();
    end
  endtask
endclass

class line_monitor extends uvm_monitor;
  `uvm_component_utils(line_monitor)
  virtual line_if vif;
  uvm_analysis_port #(eth_raw) ap;
  bit busy;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual line_if)::get(this, "", "line_vif", vif))
      `uvm_fatal("NOVIF", "line_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    eth_raw      cur;
    int unsigned idle = 1000;
    forever begin
      @(posedge vif.clk);
      if (vif.valid) begin
        if (cur == null) begin
          cur = new("raw");
          cur.gap = idle;
          busy = 1'b1;
        end
        cur.bytes.push_back(vif.data);
        idle = 0;
      end

      else begin
        if (cur != null) begin
          ap.write(cur);
          cur  = null;
          busy = 1'b0;
        end
        idle++;
      end
    end
  endtask
endclass

class line_agent extends uvm_agent;
  `uvm_component_utils(line_agent)
  uvm_sequencer #(eth_frame) sqr;
  line_driver  drv;
  line_monitor mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(eth_frame)::type_id::create("sqr", this);
    drv = line_driver::type_id::create("drv", this);
    mon = line_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

// ----------- AXI-Stream sink agent (RX output) ------------
// The driver only drives tready; the pattern comes from eth_cfg.bp_mode
class axis_sink_driver extends uvm_component;
  `uvm_component_utils(axis_sink_driver)
  virtual axis_if vif;
  eth_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual axis_if)::get(this, "", "axis_vif", vif))
      `uvm_fatal("NOVIF", "axis_vif not set")
    if (!uvm_config_db#(eth_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "eth_cfg not set")
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned phase_left = 0;
    bit          phase_ready = 1'b1;
    vif.tready = 1'b0;
    forever begin
      @(negedge vif.clk);
      case (cfg.bp_mode)
        BP_NONE:   vif.tready = 1'b1;
        BP_RAND50: vif.tready = ($urandom_range(1, 0) == 1);
        BP_RAND10: vif.tready = ($urandom_range(9, 0) == 0);
        BP_BURSTY: begin
          if (phase_left == 0) begin
            phase_ready = ~phase_ready;
            phase_left  = $urandom_range(40, 1);
          end
          phase_left--;
          vif.tready = phase_ready;
        end
      endcase
    end
  endtask
endclass

class axis_monitor extends uvm_monitor;
  `uvm_component_utils(axis_monitor)
  virtual axis_if vif;
  uvm_analysis_port #(axis_frame) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual axis_if)::get(this, "", "axis_vif", vif))
      `uvm_fatal("NOVIF", "axis_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    axis_frame cur;
    forever begin
      @(posedge vif.clk);
      if (vif.tvalid && vif.tready) begin
        if (cur == null) cur = new("axis_frame");
        cur.data.push_back(vif.tdata);
        if (vif.tlast) begin
          cur.user = vif.tuser;
          ap.write(cur);
          cur = null;
        end
      end
    end
  endtask
endclass

class axis_agent extends uvm_agent;
  `uvm_component_utils(axis_agent)
  axis_sink_driver drv;
  axis_monitor     mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    drv = axis_sink_driver::type_id::create("drv", this);
    mon = axis_monitor::type_id::create("mon", this);
  endfunction
endclass

// -------------- register agent -------------
class reg_driver extends uvm_driver #(reg_item);
  `uvm_component_utils(reg_driver)
  virtual reg_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual reg_if)::get(this, "", "reg_vif", vif))
      `uvm_fatal("NOVIF", "reg_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    vif.wr    = 1'b0;
    vif.rd    = 1'b0;
    vif.addr  = '0;
    vif.wdata = '0;
    forever begin
      seq_item_port.get_next_item(req);
      @(negedge vif.clk);
      vif.addr  = req.addr;
      vif.wdata = req.wdata;
      vif.wr    = req.write;
      vif.rd    = !req.write;
      @(negedge vif.clk);
      vif.wr = 1'b0;
      vif.rd = 1'b0;
      if (!req.write) @(negedge vif.clk); // rdata/rvalid visible during this cycle
      seq_item_port.item_done();
    end
  endtask
endclass

class reg_monitor extends uvm_monitor;
  `uvm_component_utils(reg_monitor)
  virtual reg_if vif;
  uvm_analysis_port #(reg_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual reg_if)::get(this, "", "reg_vif", vif))
      `uvm_fatal("NOVIF", "reg_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    bit [2:0] rd_addr;
    reg_item  t;
    forever begin
      @(posedge vif.clk);
      if (vif.rvalid) begin
        t = new("rd");
        t.write = 1'b0;
        t.addr  = rd_addr;
        t.rdata = vif.rdata;
        ap.write(t);
      end
      if (vif.wr) begin
        t = new("wr");
        t.write = 1'b1;
        t.addr  = vif.addr;
        t.wdata = vif.wdata;
        ap.write(t);
      end
      if (vif.rd) rd_addr = vif.addr;
    end
  endtask
endclass

class reg_agent extends uvm_agent;
  `uvm_component_utils(reg_agent)
  uvm_sequencer #(reg_item) sqr;
  reg_driver  drv;
  reg_monitor mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    sqr = uvm_sequencer#(reg_item)::type_id::create("sqr", this);
    drv = reg_driver::type_id::create("drv", this);
    mon = reg_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

// ------------ status-flag monitor --------------
class flag_monitor extends uvm_monitor;
  `uvm_component_utils(flag_monitor)
  virtual stat_if vif;
  uvm_analysis_port #(flag_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual stat_if)::get(this, "", "stat_vif", vif))
      `uvm_fatal("NOVIF", "stat_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    flag_item f;
    forever begin
      @(posedge vif.clk);
      if (vif.crc_err) begin
        f = new("f");
        f.kind = OUT_CRC;
        ap.write(f);
      end
      if (vif.runt) begin
        f = new("f");
        f.kind = OUT_RUNT;
        ap.write(f);
      end
      if (vif.oversize) begin
        f = new("f");
        f.kind = OUT_OVER;
        ap.write(f);
      end
    end
  endtask
endclass
