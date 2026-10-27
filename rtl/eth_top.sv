module eth_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        line_valid,
  input  logic [7:0]  line_data,
  output logic [7:0]  m_tdata,
  output logic        m_tvalid,
  input  logic        m_tready,
  output logic        m_tlast,
  output logic        m_tuser,
  output logic        crc_err,
  output logic        runt,
  output logic        oversize,
  output logic [31:0] frame_count,
  input  logic        reg_wr,
  input  logic        reg_rd,
  input  logic [2:0]  reg_addr,
  input  logic [31:0] reg_wdata,
  output logic [31:0] reg_rdata,
  output logic        reg_rvalid,
  output logic        cfg_enable
);
  logic        drop_on_error;
  logic [10:0] max_len;
  logic        ev_good, ev_ovfl;

  logic enable_w;
  assign cfg_enable = enable_w;

  eth_regs u_regs (
    .clk, .rst_n, .reg_wr, .reg_rd, .reg_addr, .reg_wdata, .reg_rdata, .reg_rvalid,
    .ev_good, .ev_crc(crc_err), .ev_runt(runt), .ev_over(oversize), .ev_ovfl,
    .enable(enable_w), .drop_on_error, .max_len, .frame_count
  );

  eth_rx u_rx (
    .clk, .rst_n, .line_valid, .line_data,
    .m_tdata, .m_tvalid, .m_tready, .m_tlast, .m_tuser,
    .enable(enable_w), .drop_on_error, .max_len,
    .ev_good, .ev_crc(crc_err), .ev_runt(runt), .ev_over(oversize), .ev_ovfl
  );
endmodule
