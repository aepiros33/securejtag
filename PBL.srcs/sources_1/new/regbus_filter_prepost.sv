`timescale 1ns/1ps
module regbus_filter_prepost #(
  parameter int AW = 16
)(
  input  logic          clk,
  input  logic          rst_n,

  // �ܺ� ���� In (�긮�� �� ����)
  input  logic          cs_in,
  input  logic          we_in,
  input  logic [AW-1:0] addr_in,   // ����Ʈ �ּ� ���� AW��Ʈ
  input  logic [31:0]   wdata_in,

  // ���� ���� Out (���� �� ��������/�޸� ����)
  output logic          cs_out,
  output logic          we_out,
  output logic [AW-1:0] addr_out,
  output logic [31:0]   wdata_out,

  // ���� ���� In (��������/�޸� �� ����)
  input  logic [31:0]   rdata_in,
  input  logic          rvalid_in,

  // �ܺ� ���� Out (���� �� �긮��)
  output logic [31:0]   rdata_out,
  output logic          rvalid_out,

  // ����
  input  logic          soft_lock,      // 1=LOCK
  input  logic          session_open    // 1=debug enable (auth pass or bypass@DEV)
);
  // 0x000~0x0FF: SFR (addr[8]==0), 0x100~: MEM
  wire in_sfr    = (addr_in[8] == 1'b0);
  wire prelocked = soft_lock & ~session_open;

  // ��� ����: (���/���ǿ���) �Ǵ� SFR
  wire pass = (!prelocked) || in_sfr;

  // �ٿƮ�� ���� (���ܽ� read�� �������� ����)
  assign cs_out    = cs_in  & pass;
  assign we_out    = we_in  & pass;
  assign addr_out  = addr_in;
  assign wdata_out = wdata_in;

  // ���ܵ� READ: rvalid=1, rdata=0  (�긮���� rvalid�� ���� pready�� �ø�)
  assign rvalid_out = pass ? rvalid_in        : (cs_in & ~we_in);
  assign rdata_out  = pass ? rdata_in         : 32'h0000_0000;

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (cs_in) begin
    $display("FLT %s @%0t addr=%h pass=%0d prelocked=%0d in_sfr=%0d",
             we_in ? "WR" : "RD", $time, addr_in, pass, prelocked, in_sfr);
  end
`endif
 // ===== ������� ����� �߰� =====
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (cs_in && !we_in) begin
      $display("DBG RD  pass=%0d prelocked=%0d in_sfr=%0d soft_lock=%0d session_open=%0d addr=%h @%0t",
               pass, prelocked, in_sfr, soft_lock, session_open, addr_in, $time);
    end
    if (cs_in && we_in) begin
      $display("DBG WR  pass=%0d prelocked=%0d in_sfr=%0d soft_lock=%0d session_open=%0d addr=%h @%0t",
               pass, prelocked, in_sfr, soft_lock, session_open, addr_in, $time);
    end
  end
`endif
// LOCK(soft_lock=1, session_open=0) ���� 0x100~ write ����
assert property (@(posedge clk) disable iff(!rst_n)
  (cs_in && we_in && (addr_in>=16'h0100) && (soft_lock && !session_open)) |-> !we_out);


// LOCK ���� 0x100~ read=0
assert property (@(posedge clk) disable iff(!rst_n)
  (cs_in && !we_in && (addr_in>=16'h0100) && (soft_lock && !session_open)) |-> (rvalid_out && rdata_out==32'h0));

  // ===== ����� �� =====
endmodule
