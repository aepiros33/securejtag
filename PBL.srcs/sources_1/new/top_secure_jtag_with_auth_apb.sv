`timescale 1ns/1ps
module top_secure_jtag_with_auth_apb (
  input  logic         pclk,
  input  logic         presetn,
  input  logic         psel,
  input  logic         penable,
  input  logic         pwrite,
  input  logic [31:0]  paddr,
  input  logic [31:0]  pwdata,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,
  output logic         dbg_enable_o
);
  import secure_jtag_pkg::*;

  // APB → regbus
  logic         cs, we;
  logic [15:0]  addr;
  logic [31:0]  wdata, rdata;
  logic         rvalid;

  apb_reg_bridge #(.AW(16)) u_apb2reg (
    .pclk(pclk), .presetn(presetn),
    .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .bus_cs(cs), .bus_we(we), .bus_addr(addr), .bus_wdata(wdata),
    .bus_rdata(rdata), .bus_rvalid(rvalid)
  );

  // 기존 코어를 그대로 감싸서 연결 (필터→regfile→auth/policy 라인 포함)
  top_secure_jtag_with_auth u_core (
    .clk(pclk), .rst_n(presetn),
    .cs(cs), .we(we), .addr(addr), .wdata(wdata),
    .rdata(rdata), .rvalid(rvalid),
    .dbg_enable_o(dbg_enable_o)
  );
endmodule
