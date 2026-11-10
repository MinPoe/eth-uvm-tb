class eth_env extends uvm_env;
  `uvm_component_utils(eth_env)
  line_agent    line;
  axis_agent    axis;
  reg_agent     regs;
  flag_monitor  flags;
  eth_refmodel  model;
  eth_scb       scb;
  eth_cov       cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    line  = line_agent::type_id::create("line", this);
    axis  = axis_agent::type_id::create("axis", this);
    regs  = reg_agent::type_id::create("regs", this);
    flags = flag_monitor::type_id::create("flags", this);
    model = eth_refmodel::type_id::create("model", this);
    scb   = eth_scb::type_id::create("scb", this);
    cov   = eth_cov::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    line.mon.ap.connect(model.raw_imp);
    regs.mon.ap.connect(model.reg_imp);
    regs.mon.ap.connect(scb.reg_imp);
    model.exp_ap.connect(scb.exp_imp);
    model.exp_ap.connect(cov.analysis_export);
    axis.mon.ap.connect(scb.axis_imp);
    flags.ap.connect(scb.flag_imp);
    scb.model = model;
  endfunction
endclass
