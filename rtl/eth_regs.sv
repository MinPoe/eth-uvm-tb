// Config registers + event counters 
// Simple bus: 1-cycle write, 1-cycle read, read data valid 1 cycle after reg_rd (reg_rvalid)
//
// Word addresses:
//   0 CTRL      [0] enable (reset 0)  [1] drop_on_error (reset 1)
//   1 MAX_LEN   [10:0] max body length in bytes, body = dst..FCS (reset 1518)
//   2 FRAME_CNT good frames
//   3 CRC_CNT   bad-CRC frames
//   4 RUNT_CNT  runt frames
//   5 OVER_CNT  oversize frames
//   6 OVFL_CNT  frames that should have been forwarded but found no free buffer
//   7 CLR       write any value: clears all counters (read returns 0)
module eth_regs (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        reg_wr,
  input  logic        reg_rd,
  input  logic [2:0]  reg_addr,
  input  logic [31:0] reg_wdata,
  output logic [31:0] reg_rdata,
  output logic        reg_rvalid,

  input  logic        ev_good,
  input  logic        ev_crc,
  input  logic        ev_runt,
  input  logic        ev_over,
  input  logic        ev_ovfl,

  output logic        enable,
  output logic        drop_on_error,
  output logic [10:0] max_len,
  output logic [31:0] frame_count
);
  logic [31:0] crc_cnt, runt_cnt, over_cnt, ovfl_cnt;
  logic        clr;
  assign clr = reg_wr && reg_addr == 3'd7;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enable        <= 1'b0;
      drop_on_error <= 1'b1;
      max_len       <= 11'd1518;
    end 
    
    else if (reg_wr) begin
      case (reg_addr)
        3'd0: begin 
          enable <= reg_wdata[0]; 
          drop_on_error <= reg_wdata[1]; 
        end

        `ifdef BUG_MAXLEN_W
          3'd1: max_len <= {1'b0, reg_wdata[9:0]};
        `else
          3'd1: max_len <= reg_wdata[10:0];
        `endif

        default: ;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || clr) begin
      frame_count <= '0; 
      crc_cnt <= '0; 
      runt_cnt <= '0; 
      over_cnt <= '0; 
      ovfl_cnt <= '0;
    end 
    
    else begin
      `ifdef BUG_CNT8
        if (ev_good) frame_count <= {24'b0, frame_count[7:0] + 8'd1};
      `else
        if (ev_good) frame_count <= frame_count + 32'd1;
      `endif

      `ifdef BUG_CRC_CNT_COND
        if (ev_crc && drop_on_error) crc_cnt <= crc_cnt + 32'd1;
      `else
        if (ev_crc)  crc_cnt  <= crc_cnt  + 32'd1;
      `endif

      if (ev_runt) runt_cnt <= runt_cnt + 32'd1;
      if (ev_over) over_cnt <= over_cnt + 32'd1;
      if (ev_ovfl) ovfl_cnt <= ovfl_cnt + 32'd1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_rdata  <= '0;
      reg_rvalid <= 1'b0;
    end 
    
    else begin
      reg_rvalid <= reg_rd;
      case (reg_addr)
        3'd0:    reg_rdata <= {30'b0, drop_on_error, enable};
        3'd1:    reg_rdata <= {21'b0, max_len};
        3'd2:    reg_rdata <= frame_count;
        3'd3:    reg_rdata <= crc_cnt;
        3'd4:    reg_rdata <= runt_cnt;
        3'd5:    reg_rdata <= over_cnt;
        3'd6:    reg_rdata <= ovfl_cnt;
        default: reg_rdata <= '0;
      endcase
    end
  end
endmodule
