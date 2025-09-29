`timescale 1ns/1ps
module ap_bridge_stub (
  input  logic clk, rst_n,
  input  logic en_i,          // DP가 활성일 때만 AP 브릿지 활성
  output logic ap_ready_o     // "AP 사용 가능" 플래그(가시성용)
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ap_ready_o <= 1'b0;
    else        ap_ready_o <= en_i;
  end
endmodule
