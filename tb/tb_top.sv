`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;
  import eth_pkg::*;

  logic clk = 1'b0;
  logic rst_n;
  always #5 clk = ~clk;

  line_if line_i (clk);
  axis_if axis_i (clk);
  reg_if  reg_i  (clk);
  stat_if stat_i (clk);

  initial begin
    rst_n = 1'b1;
    #1 rst_n = 1'b0; // create a falling edge so the async reset fires
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
  end

  eth_top dut (
    .clk, .rst_n,
    .line_valid (line_i.valid), .line_data (line_i.data),
    .m_tdata (axis_i.tdata), .m_tvalid (axis_i.tvalid), .m_tready (axis_i.tready),
    .m_tlast (axis_i.tlast), .m_tuser (axis_i.tuser),
    .crc_err (stat_i.crc_err), .runt (stat_i.runt), .oversize (stat_i.oversize),
    .frame_count (stat_i.frame_count),
    .reg_wr (reg_i.wr), .reg_rd (reg_i.rd), .reg_addr (reg_i.addr), .reg_wdata (reg_i.wdata),
    .reg_rdata (reg_i.rdata), .reg_rvalid (reg_i.rvalid),
    .cfg_enable (stat_i.cfg_enable)
  );

  eth_checks checks (
    .clk, .rst_n,
    .line_valid (line_i.valid),
    .tdata (axis_i.tdata), .tvalid (axis_i.tvalid), .tready (axis_i.tready),
    .tlast (axis_i.tlast), .tuser (axis_i.tuser),
    .crc_err (stat_i.crc_err), .runt (stat_i.runt), .oversize (stat_i.oversize),
    .frame_count (stat_i.frame_count), .cfg_enable (stat_i.cfg_enable),
    .reg_wr (reg_i.wr), .reg_rd (reg_i.rd), .reg_addr (reg_i.addr), .reg_rvalid (reg_i.rvalid)
  );

  initial begin
    uvm_config_db#(virtual line_if)::set(null, "*", "line_vif", line_i);
    uvm_config_db#(virtual axis_if)::set(null, "*", "axis_vif", axis_i);
    uvm_config_db#(virtual reg_if )::set(null, "*", "reg_vif",  reg_i);
    uvm_config_db#(virtual stat_if)::set(null, "*", "stat_vif", stat_i);
    run_test();
  end

  // watchdog: 80 ms = 8M cycles
  initial begin
    #80ms;
    $display("WATCHDOG_TIMEOUT");
    $fatal(1, "simulation watchdog expired");
  end
endmodule
