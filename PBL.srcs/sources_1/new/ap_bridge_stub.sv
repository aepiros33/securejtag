`timescale 1ns/1ps
module ap_bridge_stub (
  input  logic clk, rst_n,
  input  logic en_i,          // DP�� Ȱ���� ���� AP �긴�� Ȱ��
  output logic ap_ready_o     // "AP ��� ����" �÷���(���ü���)
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ap_ready_o <= 1'b0;
    else        ap_ready_o <= en_i;
  end
endmodule
