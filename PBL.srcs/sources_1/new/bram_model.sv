// bram_model.sv (TB 내부/같은 파일에 있어도 됨)
`timescale 1ns/1ps
module bram_model #(
  parameter int  AW       = 16,
  // ★ 패키지 의존 없애고 지역 파라미터로 경계 고정 (바이트 주소 기준 0x100)
  parameter logic [AW-1:0] MEM_BASE = 16'h0100
)(
  input  logic          clk, rst_n,
  input  logic          cs, we,
  input  logic [AW-1:0] addr,      // byte address
  input  logic [31:0]   wdata,
  output logic [31:0]   rdata,
  output logic          rvalid
);
  logic [31:0] mem [0:255];
  wire  [7:0] widx = addr[9:2];

  integer i;
  initial begin
    for (i=0; i<256; i++) mem[i] = 32'h0;
    mem[8'h40] = 32'hABCD_1234; // addr 0x100
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      rvalid <= 1'b0; rdata <= 32'h0;
    end else begin
      if (cs && we && (addr >= MEM_BASE)) mem[widx] <= wdata;
      rvalid <= cs && ~we && (addr >= MEM_BASE);
      if (cs && ~we && (addr >= MEM_BASE)) rdata <= mem[widx];
    end
  end
endmodule
