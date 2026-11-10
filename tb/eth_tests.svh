class eth_base_test extends uvm_test;
  `uvm_component_utils(eth_base_test)
  eth_env  env;
  eth_cfg  cfg;
  virtual line_if line_vif;
  virtual axis_if axis_vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    cfg = eth_cfg::type_id::create("cfg");
    uvm_config_db#(eth_cfg)::set(this, "*", "cfg", cfg);
    env = eth_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual line_if)::get(this, "", "line_vif", line_vif)) `uvm_fatal("NOVIF", "line_vif")
    if (!uvm_config_db#(virtual axis_if)::get(this, "", "axis_vif", axis_vif)) `uvm_fatal("NOVIF", "axis_vif")
  endfunction

  // ----------- helpers -------------
  task cfg_regs(bit en, bit drop, int unsigned max_len);
    reg_cfg_seq s = reg_cfg_seq::type_id::create("cfg_seq");
    s.enable        = en;
    s.drop_on_error = drop;
    s.max_len       = max_len;
    s.start(env.regs.sqr);
  endtask

  task read_all();
    reg_read_all_seq s = reg_read_all_seq::type_id::create("rd_seq");
    s.start(env.regs.sqr);
  endtask

  task clear_counters();
    reg_clear_seq s = reg_clear_seq::type_id::create("clr_seq");
    s.start(env.regs.sqr);
  endtask

  // line idle and no output for 100 consecutive cycles
  task wait_idle();
    int unsigned quiet = 0;
    while (quiet < 100) begin
      @(posedge line_vif.clk);
      if (env.line.mon.busy || axis_vif.tvalid) quiet = 0;
      else quiet++;
    end
  endtask

  // traffic body, overridden by each test
  virtual task traffic();
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    #200ns; // reset
    read_all(); // reset values
    traffic();
    wait_idle();
    read_all(); // counters + overflow reconciliation
    #100ns;
    phase.drop_objection(this);
  endtask
endclass

// 1. random mix, default config
class eth_rand_test extends eth_base_test;
  `uvm_component_utils(eth_rand_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task traffic();
    eth_rand_seq s = eth_rand_seq::type_id::create("s");
    cfg_regs(1, 1, 1518);
    s.n = 150;
    s.start(env.line.sqr);
  endtask
endclass

// 2. error injection, drop-on-error
class eth_err_test extends eth_base_test;
  `uvm_component_utils(eth_err_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task traffic();
    eth_err_seq s = eth_err_seq::type_id::create("s");
    cfg_regs(1, 1, 1518);
    s.n = 120;
    s.start(env.line.sqr);
  endtask
endclass

// 3. config sweep: forward-on-error, smaller max_len, random backpressure
class eth_cfg_test extends eth_base_test;
  `uvm_component_utils(eth_cfg_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task traffic();
    eth_err_seq s = eth_err_seq::type_id::create("s");
    cfg.bp_mode = BP_RAND50;
    cfg_regs(1, 0, 1518);
    s.n = 60;
    s.start(env.line.sqr);
    wait_idle();

    cfg_regs(1, 0, 1024);
    s = eth_err_seq::type_id::create("s2");
    s.n       = 60;
    s.max_len = 1024;
    s.start(env.line.sqr);
    wait_idle();

    cfg.bp_mode = BP_BURSTY;
    cfg_regs(1, 1, 600);
    s = eth_err_seq::type_id::create("s3");
    s.n       = 40;
    s.max_len = 600;
    s.start(env.line.sqr);
  endtask
endclass

// 4. back-to-back, one idle cycle between frames; >256 frames so counters must not wrap at 8 bits
class eth_b2b_test extends eth_base_test;
  `uvm_component_utils(eth_b2b_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task traffic();
    eth_b2b_seq s = eth_b2b_seq::type_id::create("s");
    cfg_regs(1, 1, 1518);
    s.n = 300;
    s.start(env.line.sqr);
  endtask
endclass

// 5. backpressure stress: slow sink, long frames, buffers fill up -> overflow accounting
class eth_bp_test extends eth_base_test;
  `uvm_component_utils(eth_bp_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task traffic();
    eth_bp_seq s = eth_bp_seq::type_id::create("s");
    cfg_regs(1, 1, 1518);
    cfg.bp_mode = BP_RAND50;
    s.n = 12;
    s.start(env.line.sqr);
    wait_idle();

    cfg.bp_mode = BP_RAND10;
    s = eth_bp_seq::type_id::create("s2");
    s.n = 10;
    s.start(env.line.sqr);
  endtask
endclass

// 6. directed corners, enable gating, counter clear
class eth_corner_test extends eth_base_test;
  `uvm_component_utils(eth_corner_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task traffic();
    eth_corner_seq c = eth_corner_seq::type_id::create("c");
    eth_rand_seq   r = eth_rand_seq::type_id::create("r");

    // disabled: frames must be ignored, nothing counted, nothing output
    cfg_regs(0, 1, 1518);
    r.n = 8;
    r.start(env.line.sqr);
    wait_idle();

    // enabled with default limits
    cfg_regs(1, 1, 1518);
    c.start(env.line.sqr);
    wait_idle();
    read_all();
    clear_counters();
    read_all();

    // new limit
    cfg_regs(1, 1, 1024);
    c = eth_corner_seq::type_id::create("c2");
    c.max_len = 1024;
    c.start(env.line.sqr);
    wait_idle();

    // disable again at the end
    cfg_regs(0, 1, 1024);
    r = eth_rand_seq::type_id::create("r2");
    r.n = 5;
    r.start(env.line.sqr);
  endtask
endclass
