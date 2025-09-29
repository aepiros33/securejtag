`timescale 1ns/1ps
module dp_wrapper_stub (
  input  logic clk, rst_n,
  input  logic dbg_enable_i,   // DAP enable (우리 design의 dbg_enable_o)
  output logic dp_active_o     // DAP block가 "활성화됨" 표시
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) dp_active_o <= 1'b0;
    else        dp_active_o <= dbg_enable_i;
  end
endmodule
