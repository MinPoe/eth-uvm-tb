typedef enum {ERR_NONE, ERR_BAD_CRC, ERR_RUNT, ERR_OVERSIZE, ERR_TRUNC, ERR_B2B} err_e;
typedef enum {OUT_GOOD, OUT_CRC, OUT_RUNT, OUT_OVER, OUT_IGNORED, OUT_DISABLED} outcome_e;
typedef enum {BP_NONE, BP_RAND50, BP_RAND10, BP_BURSTY} bp_e;

// Register word addresses
localparam bit [2:0] A_CTRL = 3'd0, A_MAXLEN = 3'd1, A_FRAMES = 3'd2, A_CRC = 3'd3, A_RUNT = 3'd4, A_OVER = 3'd5, A_OVFL = 3'd6, A_CLR = 3'd7;

// Normal (shift-left) Form Reflected CRC-32
//     credits : https://github.com/Michaelangel007/crc32
function automatic bit [31:0] ref_crc32(byte unsigned data[$]);
  bit [31:0] crc;
  bit [31:0] r;
  bit top;
  crc = 32'hFFFF_FFFF;
  foreach (data[k]) begin

    for (int i = 0; i < 8; i++) begin
      top = crc[31] ^ data[k][i];
      crc = crc << 1;

      if (top) begin 
        crc = crc ^ 32'h04C1_1DB7;
      end
    end

  end

  for (int i = 0; i < 32; i++) begin 
    r[i] = crc[31 - i];
  end

  return ~r;
endfunction

class eth_cfg extends uvm_object;
  `uvm_object_utils(eth_cfg)
  bp_e bp_mode = BP_NONE;   // read every cycle by the AXI-Stream sink driver

  function new(string name = "eth_cfg");
    super.new(name);
  endfunction
endclass


class eth_frame extends uvm_sequence_item;
  // 14 byte header 
  `uvm_object_utils(eth_frame)
  rand bit [47:0]    dst, src;
  rand bit [15:0]    etype;

  rand int unsigned  payload_len;
  rand int unsigned  bucket;     // picks the payload-length class
  rand int unsigned  rbucket;    // for runt

  // error type 
  rand err_e         err;

  rand int unsigned  ifg;        // idle cycles after the frame (>=1)
  rand int unsigned  pre_len;    // number of 0x55 preamble bytes (>=1)
  rand int unsigned  runt_len;   // body bytes kept for ERR_RUNT

  rand bit [31:0]    fcs_flip;   // XOR mask applied to FCS for ERR_BAD_CRC

  // config bank
  int unsigned       max_len = 1518;   // DUT config as known by the sequence

  // output buffers
  byte unsigned      payload[$];
  byte unsigned      wbytes[$];          // bytes driven on the line (valid high)

  constraint c_err { err dist {ERR_NONE := 50, ERR_BAD_CRC := 10, ERR_RUNT := 10, ERR_OVERSIZE := 10, ERR_TRUNC := 5, ERR_B2B := 15}; }
  constraint c_bucket { bucket inside {[0:9]}; rbucket inside {[0:9]}; }
  constraint c_len {
    payload_len <= 2000;

    if (err == ERR_OVERSIZE) {
      payload_len >= max_len - 17;
      payload_len <= max_len + 400;
    } else {
      payload_len + 18 <= max_len;
      // buckets ensure better distribution of test cases
      (bucket == 0)              -> payload_len == 0;
      (bucket inside {1, 2, 3})  -> payload_len inside {[1:45]};
      (bucket == 4)              -> payload_len == 46;
      (bucket inside {5, 6, 7})  -> payload_len inside {[47:1499]};
      (bucket inside {8, 9})     -> payload_len inside {[1000:1500]};
    }

  }
  constraint c_runt   { (rbucket < 3) -> runt_len == 63;
                        (rbucket inside {3, 4}) -> runt_len inside {[0:17]};
                        (rbucket >= 5) -> runt_len inside {[18:62]}; }

  constraint c_pre    { (bucket < 7) -> pre_len == 7; pre_len inside {[1:7]}; }
  constraint c_ifg    { (err == ERR_B2B) -> ifg == 1; ifg inside {[1:24]}; }
  
  // XOR flip for corrupting the checksum
  constraint c_flip   { fcs_flip != 0; }

  function new(string name = "eth_frame");
    super.new(name);
  endfunction

  // Build payload bytes and the on-wbytes byte stream from the randomized fields
  function void build();
    byte unsigned body[$];
    byte unsigned padded[$];
    bit [31:0]    fcs;
    byte unsigned all_body[$];

    payload.delete();

    for (int i = 0; i < payload_len; i++) begin 
      payload.push_back($urandom_range(255, 0));
    end

    padded = payload;

    while (padded.size() < 46) begin 
      padded.push_back(8'h00);
    end 
    
    for (int i = 5; i >= 0; i--) begin
      body.push_back(dst[8*i +: 8]);
    end

    for (int i = 5; i >= 0; i--) begin
      body.push_back(src[8*i +: 8]);
    end

    body.push_back(etype[15:8]);
    body.push_back(etype[7:0]);

    foreach (padded[i]) begin
      body.push_back(padded[i]);
    end

    fcs = ref_crc32(body);

    if (err == ERR_BAD_CRC) begin
      fcs = fcs ^ fcs_flip;
    end

    all_body = body;

    for (int i = 0; i < 4; i++) begin
      all_body.push_back(fcs[8*i +: 8]); // FCS on the wbytes LSB first
    end

    wbytes.delete();

    for (int i = 0; i < pre_len; i++) begin
      wbytes.push_back(8'h55);
    end

    if (err == ERR_TRUNC) begin
      if (fcs_flip[0]) begin
        wbytes.push_back(8'hAA); // garbage instead of SFD
      end
    end

    else begin
      wbytes.push_back(8'hD5);

      if (err == ERR_RUNT) begin
        for (int i = 0; i < runt_len; i++) begin
          wbytes.push_back(all_body[i]);
        end
      end

      else begin
        foreach (all_body[i]) begin
          wbytes.push_back(all_body[i]);
        end
      end
    end
  endfunction

  function string convert2string();
    return $sformatf("err=%s payload_len=%0d runt_len=%0d ifg=%0d pre=%0d wbytes=%0d bytes",
                     err.name(), payload_len, runt_len, ifg, pre_len, wbytes.size());
  endfunction
endclass

// Line monitor, bytes[] when 'valid' high and gap during idle cycles  
class eth_raw extends uvm_object;
  `uvm_object_utils(eth_raw)
  byte unsigned bytes[$];
  int unsigned  gap;

  function new(string name = "eth_raw");
    super.new(name);
  endfunction
endclass

// Frame outcome prediction
class eth_exp extends uvm_object;
  `uvm_object_utils(eth_exp)
  outcome_e     outcome;
  int unsigned  body_len;
  bit           forward;
  bit           user;
  byte unsigned payload[$];
  bit           drop_on_error, enable;
  int unsigned  max_len, gap;
  bp_e          bp;

  function new(string name = "eth_exp");
    super.new(name);
  endfunction
endclass

// Actual output of AXI-Stream 
class axis_frame extends uvm_object;
  `uvm_object_utils(axis_frame)
  byte unsigned data[$];
  bit           user;

  function new(string name = "axis_frame");
    super.new(name);
  endfunction
endclass

// drives register file
class reg_item extends uvm_sequence_item;
  `uvm_object_utils(reg_item)
  rand bit        write;
  rand bit [2:0]  addr;
  rand bit [31:0] wdata;
  bit      [31:0] rdata;

  function new(string name = "reg_item");
    super.new(name);
  endfunction
endclass

// flag outputs
class flag_item extends uvm_object;
  `uvm_object_utils(flag_item)
  outcome_e kind; // OUT_CRC, OUT_RUNT or OUT_OVER

  function new(string name = "flag_item");
    super.new(name);
  endfunction
endclass
