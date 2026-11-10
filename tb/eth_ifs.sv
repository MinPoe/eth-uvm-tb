interface line_if (input logic clk);
  logic       valid;
  logic [7:0] data;
endinterface

interface axis_if (input logic clk);
  logic [7:0] tdata;
  logic       tvalid;
  logic       tready;
  logic       tlast;
  logic       tuser;
endinterface

interface reg_if (input logic clk);
  logic        wr;
  logic        rd;
  logic [2:0]  addr;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic        rvalid;
endinterface

// DUT status outputs observed by the testbench
interface stat_if (input logic clk);
  logic        crc_err;
  logic        runt;
  logic        oversize;
  logic [31:0] frame_count;
  logic        cfg_enable;
endinterface

// Protocol / behaviour assertions, bound by connection in tb_top
module eth_checks (
  input logic        clk,
  input logic        rst_n,
  input logic        line_valid,
  input logic [7:0]  tdata,
  input logic        tvalid,
  input logic        tready,
  input logic        tlast,
  input logic        tuser,
  input logic        crc_err,
  input logic        runt,
  input logic        oversize,
  input logic [31:0] frame_count,
  input logic        cfg_enable,
  input logic        reg_wr,
  input logic        reg_rd,
  input logic [2:0]  reg_addr,
  input logic        reg_rvalid
);
  logic clr;
  assign clr = reg_wr && (reg_addr == 3'd7);

  // AXI-Stream source rules
  a_valid_stable : assert property (@(posedge clk) disable iff (!rst_n) tvalid && !tready |=> tvalid)
    else $error("AXIS: tvalid dropped before tready");

  a_data_stable  : assert property (@(posedge clk) disable iff (!rst_n) tvalid && !tready |=> $stable(tdata))
    else $error("AXIS: tdata changed while stalled");
  
  a_last_stable  : assert property (@(posedge clk) disable iff (!rst_n) tvalid && !tready |=> $stable(tlast))
    else $error("AXIS: tlast changed while stalled");
  
  a_user_stable  : assert property (@(posedge clk) disable iff (!rst_n) tvalid && !tready |=> $stable(tuser))
    else $error("AXIS: tuser changed while stalled");
  
  a_last_needs_v : assert property (@(posedge clk) disable iff (!rst_n) tlast |-> tvalid)
    else $error("AXIS: tlast without tvalid");
  
  a_no_valid_rst : assert property (@(posedge clk) !rst_n |-> !tvalid)
    else $error("AXIS: tvalid during reset");


  // No new output frame while the block is disabled
  a_no_out_dis : assert property (@(posedge clk) disable iff (!rst_n) $rose(tvalid) |-> cfg_enable)
    else $error("RX: output started while disabled");

  // Status flags
  a_flags_1hot : assert property (@(posedge clk) disable iff (!rst_n) $onehot0({crc_err, runt, oversize}))
    else $error("RX: more than one error flag in the same cycle");

  // frame_count
  a_cnt_step : assert property (@(posedge clk) disable iff (!rst_n) !$past(clr) |-> (frame_count - $past(frame_count)) <= 32'd1)
    else $error("CNT: frame_count moved by more than +1 or went backwards");
  
  a_cnt_clr : assert property (@(posedge clk) disable iff (!rst_n) $past(clr) |-> frame_count == 32'd0)
    else $error("CNT: frame_count not cleared");


  // Register read timing
  a_rvalid : assert property (@(posedge clk) disable iff (!rst_n) reg_rvalid == $past(reg_rd))
    else $error("REG: rvalid not exactly one cycle after rd");

  // Scenario covers (show that stimulus reached these situations)
  c_stall_then_go : cover property (@(posedge clk) disable iff (!rst_n) tvalid && !tready ##1 tvalid && tready);
  c_zero_ifg : cover property (@(posedge clk) disable iff (!rst_n) $fell(line_valid) ##1 line_valid);

endmodule
