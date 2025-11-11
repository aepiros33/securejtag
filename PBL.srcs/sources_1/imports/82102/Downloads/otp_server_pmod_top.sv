// ============================================================================
// otp_server_pmod_top.sv - Minimal top for FPGA2 running OTP device over PMOD
// (PMOD 전용 otp_server_link와 호환 / EMFI pre-trigger em_trig_o 출력)
// ============================================================================
`timescale 1ns/1ps
module otp_server_pmod_top #(
  parameter bit F_SOFT_RAW = 1'b0
)(
  input  wire        CLK100MHZ,
  input  logic [3:0] btn,
  input  logic [3:0] sw,         // DIP 스위치
  input  wire        otp_sclk,
  input  wire        otp_req,
  input  wire [1:0]  otp_cmd,
  output wire        otp_ack,
  output wire [3:0]  otp_dout,
  output logic [3:0] led,
  // ★ EMFI 장비 트리거용 출력 (PMOD/외부로 내보냄)
  output wire        em_trig_o,
  // ★ RGB LED1 Blue 핀에도 트리거를 표시
  output wire        led1_b,

  // (선언만 되어 있던 포트 - 사용 안 함이면 제거 가능)
  input  logic       soft_lock_r
);

  // Reset: 버튼 0번 (active high) -> 내부 active low
  wire rst_n = ~btn[0];

  // 스위치 동기화
  logic [2:0] sw0_sync;
  always_ff @(posedge CLK100MHZ or negedge rst_n) begin
    if (!rst_n) sw0_sync <= 3'b000;
    else        sw0_sync <= {sw0_sync[1:0], sw[0]};
  end
  wire soft_lock_sw = sw0_sync[2]; // 1이면 해제(디버그 허용), 0이면 잠금

  // --------------------------------------------------------------------------
  // OTP server link
  //  - RESP_DELAY_US=0 이어도 PRETRIG_ADV_CYC(기본 20클럭)만큼은
  //    응답 전에 em_trig_o가 먼저 발생
  //  - PRETRIG_STRETCH_CYC=300(?3?s @100MHz)로 Pi/LA에서 가시성 확보
  // --------------------------------------------------------------------------
  otp_server_link #(
    .CMDW                   (2),
    .CLK_HZ                 (100_000_000),
    .RESP_DELAY_US          (0),      // 의도 지연 0us
    .ACK_STRETCH_CYC        (4),      // ACK 4클럭 유지
    .PRETRIG_ADV_CYC        (20),     // 응답 20클럭 전에 사전 트리거
    .PRETRIG_STRETCH_CYC    (300)     // 트리거 펄스 폭 ?3?s
  ) u_otp_dev (
    .clk        (CLK100MHZ),
    .rst_n      (rst_n),
    .soft_lock_i(soft_lock_sw),

    .otp_sclk   (otp_sclk),
    .otp_req    (otp_req),
    .otp_cmd    (otp_cmd),
    .otp_ack    (otp_ack),
    .otp_dout   (otp_dout),

    .em_trig_o  (em_trig_o),

    // APB dump (필요시만 사용; 여기서는 고정 값)
    .psel       (1'b1),
    .paddr      (8'h00),
    .prdata     (/* unused */),
    .pready     (/* unused */)
  );

  // ★ 트리거를 LED1 Blue에도 표시 (보드에 따라 극성이 다르면 ~em_trig_o로 반전)
  assign led1_b = em_trig_o;

  // LED 상태(soft_lock) 표시
  always_ff @(posedge CLK100MHZ or negedge rst_n) begin
    if (!rst_n) led <= 4'b0000;
    else        led <= soft_lock_sw ? 4'b0001 : 4'b1100;
  end

endmodule
