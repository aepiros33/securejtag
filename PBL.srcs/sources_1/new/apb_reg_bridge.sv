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

// ---- 원래 핸드셰이크 보존 + SFR은 zero-wait ----
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
        // ★ SFR: zero-wait로 즉시 응답 (보드에서 rvalid 미반응 방지)
        pready <= 1'b1;
        prdata <= bus_rdata;   // regfile이 조합 rdata_q를 내주므로 OK
      end else begin
        // MEM: 기존대로 rvalid에 동기
        pready <= bus_rvalid;
        if (bus_rvalid) prdata <= bus_rdata;
      end
    end
    else if (write_req) begin
      // write는 전구간 zero-wait
      pready <= 1'b1;
    end
  end
end

  `ifdef LOGGING
always_ff @(posedge pclk) begin
  if (psel && penable) begin
    $display("BRIDGE acc=%0d pwrite=%0d bus_cs=%0d bus_we=%0d paddr=%h @%0t",
             (psel&penable), pwrite, bus_cs, bus_we, paddr, $time);
  end
end
`endif

endmodule
