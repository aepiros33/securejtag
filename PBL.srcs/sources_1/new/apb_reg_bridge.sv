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
  // ���� �ּ�/������
assign bus_addr  = paddr[AW-1:0];
assign bus_wdata = pwdata;
wire acc      = psel & penable;
wire read_req = acc & ~pwrite;
wire write_req= acc &  pwrite;

// 0x000~0x0FF�� SFR�� ���� (byte address ����)
wire in_sfr   = (bus_addr[15:8] == 8'h00);

// ---- ���� �ڵ����ũ ���� + SFR�� zero-wait ----
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
        // �� SFR: zero-wait�� ��� ���� (���忡�� rvalid �̹��� ����)
        pready <= 1'b1;
        prdata <= bus_rdata;   // regfile�� ���� rdata_q�� ���ֹǷ� OK
      end else begin
        // MEM: ������� rvalid�� ����
        pready <= bus_rvalid;
        if (bus_rvalid) prdata <= bus_rdata;
      end
    end
    else if (write_req) begin
      // write�� ������ zero-wait
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
