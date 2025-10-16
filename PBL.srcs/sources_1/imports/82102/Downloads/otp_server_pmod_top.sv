// ============================================================================
// otp_server_pmod_top.sv - Minimal top for FPGA2 running OTP device over PMOD
// ============================================================================

`timescale 1ns/1ps
module otp_server_pmod_top #(
    // raw eFuse 값(정의: 1=디버그 허용 BYPASS, 0=인증대기) ← 지금 바뀐 의미대로라면 이렇게
    parameter bit F_SOFT_RAW = 1'b0
  )(
    input  wire CLK100MHZ,
    input  logic [3:0] btn,
    input  logic [3:0] sw,        // ★ 보드 스위치
    input  wire otp_sclk,
    input  wire otp_req,
    input  wire [1:0] otp_cmd,
    output wire otp_ack,
    output wire [3:0] otp_dout,
    output logic [3:0] led,
    input logic soft_lock_r
  );
  logic soft_lock_val = 1'b0;
  // --------------------------------------------------------------------------
  // 0. Reset (버튼 0번 사용, active high → 내부 active low)
  // --------------------------------------------------------------------------
  wire rst_n = ~btn[0];   // 버튼 누르면 리셋

  // ★ 스위치 동기화(2~3FF)
  logic [2:0] sw0_sync;
  always_ff @(posedge CLK100MHZ or negedge rst_n) begin
    if (!rst_n) sw0_sync <= 3'b000;
    else        sw0_sync <= {sw0_sync[1:0], sw[0]};
  end
  wire soft_lock_sw = sw0_sync[2];   // 0이면 잠금, 1이면 해제(네가 원한 그대로)
  // --------------------------------------------------------------------------
  // 1. SCLK 동기화 및 상승엣지 검출
  // --------------------------------------------------------------------------
  reg [2:0] sclk_sync;
  always @(posedge CLK100MHZ or negedge rst_n) begin
    if (!rst_n)
      sclk_sync <= 3'b000;
    else
      sclk_sync <= {sclk_sync[1:0], otp_sclk};
  end

  wire sclk_rise = (sclk_sync[2:1] == 2'b01);

  // --------------------------------------------------------------------------
  // 2. OTP server link
  // --------------------------------------------------------------------------
  otp_server_link #(
    .CMDW(2),
    .USE_PMOD(1'b1),
    .OTP_SOFTLOCK(1'b0) // 이제 의미없지
  ) u_otp_dev (
    .clk        (CLK100MHZ),
    .rst_n      (rst_n),
    .soft_lock_i(soft_lock_sw),     // ★ 여기!
    .otp_sclk   (otp_sclk),
    .otp_req    (otp_req),
    .otp_cmd    (otp_cmd),
    .otp_ack    (otp_ack),
    .otp_dout   (otp_dout),
    .cmd_valid  (sclk_rise),
    .cmd_code   (2'b00),
    .data_valid (),
    .data_nib   (),
    // APB dump
    .psel   (1'b1),        // ? 항상 선택
    .paddr  (8'h00),       // Vivado HW_AXI에서 실제 주소 전달되지 않아도 OK
    .prdata (),
    .pready ()
  );

  // LED 표시(원하는 의미로)
  always_ff @(posedge CLK100MHZ or negedge rst_n) begin
    if (!rst_n) led <= 4'b0000;
    else begin
      // soft_lock_sw=1 → 소프트락=1
      // 네 설명대로라면 softlock=1은 "debug port enable" (BYPASS=1)
      led <= soft_lock_sw ? 4'b0001 : 4'b1100;
    end
  end
endmodule
