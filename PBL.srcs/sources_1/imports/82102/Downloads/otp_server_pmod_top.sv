// ============================================================================
// otp_server_pmod_top.sv - Minimal top for FPGA2 running OTP device over PMOD
// ============================================================================

`timescale 1ns/1ps
module otp_server_pmod_top #(
    // raw eFuse ��(����: 1=����� ��� BYPASS, 0=�������) �� ���� �ٲ� �ǹ̴�ζ�� �̷���
    parameter bit F_SOFT_RAW = 1'b0
  )(
    input  wire CLK100MHZ,
    input  logic [3:0] btn,
    input  logic [3:0] sw,        // �� ���� ����ġ
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
  // 0. Reset (��ư 0�� ���, active high �� ���� active low)
  // --------------------------------------------------------------------------
  wire rst_n = ~btn[0];   // ��ư ������ ����

  // �� ����ġ ����ȭ(2~3FF)
  logic [2:0] sw0_sync;
  always_ff @(posedge CLK100MHZ or negedge rst_n) begin
    if (!rst_n) sw0_sync <= 3'b000;
    else        sw0_sync <= {sw0_sync[1:0], sw[0]};
  end
  wire soft_lock_sw = sw0_sync[2];   // 0�̸� ���, 1�̸� ����(�װ� ���� �״��)
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
    .CLK_HZ(100_000_000),
    .RESP_DELAY_US(1850),     // 0.5ms
    .ACK_STRETCH_CYC(4)      // ACK 4Ŭ�� ����
  ) u_otp_dev (
    .clk        (CLK100MHZ),
    .rst_n      (rst_n),
    .soft_lock_i(soft_lock_sw),     // �� ����!
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

  // LED ǥ��(���ϴ� �ǹ̷�)
  always_ff @(posedge CLK100MHZ or negedge rst_n) begin
    if (!rst_n) led <= 4'b0000;
    else begin
      // soft_lock_sw=1 �� ����Ʈ��=1
      // �� �����ζ�� softlock=1�� "debug port enable" (BYPASS=1)
      led <= soft_lock_sw ? 4'b0001 : 4'b1100;
    end
  end
endmodule
