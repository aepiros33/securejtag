`timescale 1ns/1ps
module regbus_filter_prepost #(
  parameter int AW = 16,
  parameter logic [AW-1:0] PRE_LOW  = '0,
  parameter logic [AW-1:0] PRE_HIGH = '0
)(
  input  logic          clk, rst_n,
  // 외부 버스 In
  input  logic          cs_in, we_in,
  input  logic [AW-1:0] addr_in,
  input  logic [31:0]   wdata_in,
  // 내부 버스 Out (→ regfile)
  output logic          cs_out, we_out,
  output logic [AW-1:0] addr_out,
  output logic [31:0]   wdata_out,
  // 내부 버스 In (regfile →)
  input  logic [31:0]   rdata_in,
  input  logic          rvalid_in,
  // 외부 버스 Out
  output logic [31:0]   rdata_out,
  output logic          rvalid_out,
  // 상태
  input  logic          soft_lock,      // 1=LOCK
  input  logic          session_open    // dbg_session_en
);
  wire prelocked   = soft_lock & ~session_open;
  wire allowed_pre = (addr_in >= PRE_LOW) && (addr_in <= PRE_HIGH);
  wire pass        = !prelocked || allowed_pre;

  assign cs_out    = cs_in  & pass;
  assign we_out    = we_in  & pass;
  assign addr_out  = addr_in;
  assign wdata_out = wdata_in;
  
  // AFTER (조합 패스스루)  ← 이 두 줄로 교체
  assign rvalid_out = pass ? rvalid_in         : (cs_in & ~we_in);
  assign rdata_out  = pass ? rdata_in          : 32'h0000_0000;

  `ifdef LOGGING
  always_ff @(posedge clk) if (cs_in) begin
    $display("FLT %s @%0t addr=%h pass=%0d prelocked=%0d allowed_pre=%0d",
           we_in ? "WR" : "RD", $time, addr_in, pass, prelocked, allowed_pre);
  end
  `endif

endmodule
