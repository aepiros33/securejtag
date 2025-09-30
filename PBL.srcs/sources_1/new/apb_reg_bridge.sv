`timescale 1ns/1ps
module apb_reg_bridge #(
  parameter int AW = 16
)(
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

  // simple reg bus
  output logic         bus_cs,
  output logic         bus_we,
  output logic [AW-1:0]bus_addr,
  output logic [31:0]  bus_wdata,
  input  logic [31:0]  bus_rdata,
  input  logic         bus_rvalid
);
  // 내부 주소/엑세스
assign bus_addr  = paddr[AW-1:0];
assign bus_wdata = pwdata;
wire acc      = psel & penable;
wire read_req = acc & ~pwrite;
wire write_req= acc &  pwrite;

// 0x000~0x0FF를 SFR로 간주 (byte address 기준)
wire in_sfr   = (bus_addr[15:8] == 8'h00);

// ★ forward 제어 신호를 레지스터로 안정화
logic bus_cs_q, bus_we_q;
always_ff @(posedge pclk or negedge presetn) begin
  if (!presetn) begin
    bus_cs_q <= 1'b0;
    bus_we_q <= 1'b0;
  end else begin
    bus_cs_q <= acc;
    bus_we_q <= acc & pwrite;
  end
end

assign bus_cs = bus_cs_q;
assign bus_we = bus_we_q;

// ★ read 응답: SFR은 zero-wait, MEM은 rvalid 동기 (기존 유지)
always_ff @(posedge pclk or negedge presetn) begin
  if(!presetn) begin
    pready  <= 1'b0;
    prdata  <= 32'h0;
    pslverr <= 1'b0;
  end else begin
    pslverr <= 1'b0;
    pready  <= 1'b0;

    if (read_req) begin
      if (in_sfr) begin
        pready <= 1'b1;               // SFR: 즉시 응답
        prdata <= bus_rdata;          // regfile 조합값
      end else begin
        pready <= bus_rvalid;         // MEM: rvalid 동기
        if (bus_rvalid) prdata <= bus_rdata;
      end
    end else if (write_req) begin
      pready <= 1'b1;                 // WRITE: zero-wait
    end
  end
end
  `ifndef SYNTHESIS
always_ff @(posedge pclk) begin
  if (psel && penable) begin
    $display("BRIDGE acc=%0d pwrite=%0d bus_cs=%0d bus_we=%0d paddr=%h @%0t",
             (psel&penable), pwrite, bus_cs, bus_we, paddr, $time);
  end
  if (acc) begin
    $display("BR acc=%0d wr=%0d  bus_cs=%0d bus_we=%0d  sfr=%0d  rvalid=%0d  @%0t",
             acc, pwrite, bus_cs, bus_we, in_sfr, bus_rvalid, $time);
  end
end
`endif

endmodule
