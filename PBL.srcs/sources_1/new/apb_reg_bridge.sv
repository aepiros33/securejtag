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
  assign bus_addr  = paddr[AW-1:0];
  assign bus_wdata = pwdata;

  wire acc = psel & penable;
  assign bus_cs = acc;
  assign bus_we = acc & pwrite;

  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin
      pready  <= 1'b0;
      prdata  <= 32'h0;
      pslverr <= 1'b0;
    end else begin
      if (acc) begin
        if (pwrite) begin
          pready  <= 1'b1;    // write: zero-wait
          pslverr <= 1'b0;
        end else begin
          pready  <= bus_rvalid;  // read: rvalid µ¿±â
          prdata  <= bus_rdata;
          pslverr <= 1'b0;
        end
      end else begin
        pready  <= 1'b0;
        pslverr <= 1'b0;
      end
    end
  end
endmodule
