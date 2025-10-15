// ============================================================================
// otp_server_pmod_top.sv - Minimal top for FPGA2 running OTP device over PMOD
// ============================================================================

`timescale 1ns/1ps
module otp_server_pmod_top (
  input  wire CLK100MHZ,
  input  logic [3:0]  btn,
  input  wire otp_sclk,   // PMOD JA2
  input  wire otp_req,    // PMOD JA1
  input  wire [1:0] otp_cmd,
  output wire otp_ack,    // PMOD JA3
  output wire [3:0] otp_dout,
  output logic [3:0] led   // LED0~LED3
);

  // --------------------------------------------------------------------------
  // 0. Reset (��ư 0�� ���, active high �� ���� active low)
  // --------------------------------------------------------------------------
  wire rst_n = ~btn[0];   // ��ư ������ ����

  // --------------------------------------------------------------------------
  // 1. SCLK ����ȭ �� ��¿��� ����
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
    .OTP_SOFTLOCK(1'b0)
  ) u_otp_dev (
    .clk        (CLK100MHZ),
    .rst_n      (rst_n),
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
    .psel   (1'b1),        // ? �׻� ����
    .paddr  (8'h00),       // Vivado HW_AXI���� ���� �ּ� ���޵��� �ʾƵ� OK
    .prdata (),
    .pready ()
  );

  // --------------------------------------------------------------------------
  // 3. LED ǥ��
  //    - ���� ���� : LED OFF
  //    - ���� ���� �� : LED0, LED1 ON (�������� OFF)
  // --------------------------------------------------------------------------
  always @(posedge CLK100MHZ or negedge rst_n) begin
    if (!rst_n)
      led <= 4'b0000;
    else
      led <= 4'b0011;  // LED0, LED1 ����
  end

endmodule
