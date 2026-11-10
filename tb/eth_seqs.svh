// ---------- line-side sequences ------------
class eth_base_seq extends uvm_sequence #(eth_frame);
  `uvm_object_utils(eth_base_seq)
  int unsigned n       = 50;
  int unsigned max_len = 1518;

  function new(string name = "eth_base_seq");
    super.new(name);
  endfunction
  // hook: extra constraints per sequence
  virtual function bit gen(eth_frame f);
    return f.randomize();
  endfunction

  task body();
    repeat (n) begin
      req = eth_frame::type_id::create("req");
      req.max_len = max_len;
      start_item(req);
      if (!gen(req)) `uvm_fatal("RAND", "frame randomization failed")
      finish_item(req);
    end
  endtask
endclass

// random mix over every error kind (default)
class eth_rand_seq extends eth_base_seq;
  `uvm_object_utils(eth_rand_seq)

  function new(string name = "eth_rand_seq");
    super.new(name);
  endfunction
endclass

// error injection: bad CRC / runt / oversize / truncated, 20% clean frames
class eth_err_seq extends eth_base_seq;
  `uvm_object_utils(eth_err_seq)

  function new(string name = "eth_err_seq");
    super.new(name);
  endfunction

  virtual function bit gen(eth_frame f);
    return f.randomize() with { err dist {ERR_NONE := 2, ERR_BAD_CRC := 3, ERR_RUNT := 3, ERR_OVERSIZE := 3, ERR_TRUNC := 1}; };
  endfunction
endclass

// back-to-back burst, one idle cycle between frames, short payloads (many frames, cheap)
class eth_b2b_seq extends eth_base_seq;
  `uvm_object_utils(eth_b2b_seq)

  function new(string name = "eth_b2b_seq");
    super.new(name);
  endfunction

  virtual function bit gen(eth_frame f);
    return f.randomize() with { err == ERR_B2B; payload_len <= 60; };
  endfunction
endclass

// backpressure stress: long frames, minimum gap, sink backpressure set by the caller via eth_cfg
class eth_bp_seq extends eth_base_seq;
  `uvm_object_utils(eth_bp_seq)

  function new(string name = "eth_bp_seq");
    super.new(name);
  endfunction

  virtual function bit gen(eth_frame f);
    return f.randomize() with { err inside {ERR_NONE, ERR_B2B, ERR_BAD_CRC}; payload_len inside {[300:1500]}; ifg inside {[1:3]}; };
  endfunction
endclass

// directed corner cases around the length limits, relative to the configured max_len
class eth_corner_seq extends eth_base_seq;
  `uvm_object_utils(eth_corner_seq)

  function new(string name = "eth_corner_seq");
    super.new(name);
  endfunction

  task send(err_e e, int unsigned plen, int unsigned rlen = 0);
    req = eth_frame::type_id::create("req");
    req.max_len = max_len;
    start_item(req);
    if (!req.randomize() with { err == e; payload_len == plen; runt_len == rlen; ifg inside {[1:6]}; })
      `uvm_fatal("RAND", "corner randomization failed")
    finish_item(req);
  endtask

  task body();
    // good frames at the minimum: payload 0 (padded to 46), 1, 45, 46, 47
    send(ERR_NONE, 0);
    send(ERR_NONE, 1);
    send(ERR_NONE, 45);
    send(ERR_NONE, 46);
    send(ERR_NONE, 47);

    // runts around the 64-byte boundary
    send(ERR_RUNT, 0, 0);
    send(ERR_RUNT, 10, 17);
    send(ERR_RUNT, 10, 18);
    send(ERR_RUNT, 20, 62);
    send(ERR_RUNT, 20, 63);
    send(ERR_NONE, 46); // exactly 64: must pass

    // largest legal frame (body == max_len) and the first oversize frame (body == max_len + 1)
    send(ERR_NONE, max_len - 18);
    send(ERR_OVERSIZE, max_len - 17);
    send(ERR_OVERSIZE, max_len - 17 + 100);
    send(ERR_NONE, max_len - 19);
    send(ERR_BAD_CRC, max_len - 18);

    // preamble-only and garbage-after-preamble frames are ignored
    send(ERR_TRUNC, 0);
    send(ERR_TRUNC, 0);
    send(ERR_NONE, 100);
  endtask
endclass

// ------------- register sequences -----------
class reg_cfg_seq extends uvm_sequence #(reg_item);
  `uvm_object_utils(reg_cfg_seq)
  bit          enable        = 1;
  bit          drop_on_error = 1;
  int unsigned max_len       = 1518;

  function new(string name = "reg_cfg_seq");
    super.new(name);
  endfunction

  task wr(bit [2:0] a, bit [31:0] d);
    req = reg_item::type_id::create("req");
    start_item(req);
    req.write = 1;
    req.addr  = a;
    req.wdata = d;
    finish_item(req);
  endtask

  task body();
    wr(A_MAXLEN, max_len);
    wr(A_CTRL, {30'b0, drop_on_error, enable});
  endtask
endclass

class reg_clear_seq extends reg_cfg_seq;
  `uvm_object_utils(reg_clear_seq)

  function new(string name = "reg_clear_seq");
    super.new(name);
  endfunction

  task body();
    wr(A_CLR, 32'h1);
  endtask
endclass

class reg_read_all_seq extends uvm_sequence #(reg_item);
  `uvm_object_utils(reg_read_all_seq)

  function new(string name = "reg_read_all_seq");
    super.new(name);
  endfunction

  task body();
    for (int a = 0; a < 8; a++) begin
      req = reg_item::type_id::create("req");
      start_item(req);
      req.write = 0;
      req.addr  = a[2:0];
      req.wdata = 0;
      finish_item(req);
    end
  endtask
endclass
