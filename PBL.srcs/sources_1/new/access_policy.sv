// access_policy.sv  (FINAL, BYPASS ��� ����)
`timescale 1ns/1ps
module access_policy (
  input  logic        soft_lock,          // 1�̸� BYPASS(���� ����)
  input  logic [2:0]  lcs,                // DEV=3'b010 ����
  input  logic [5:0]  tzpc,
  input  logic [3:0]  domain,
  input  logic [3:0]  access_lv,
  input  logic        auth_pass,          // from auth FSM (PK/SIG ���� OK)
  input  logic        bypass_en,          // �� BYPASS_EN (SFR����)
  output logic        dbgen,              // final debug enable (session_open)
  output logic [7:0]  why_denied          // reason bits (�ɼ�)
);
  import secure_jtag_pkg::*;

  always_comb begin
    dbgen      = 1'b0;
    why_denied = '0;

    // [�ٽ�] soft_lock=1�̸� �ٷ� ����
    if (soft_lock) begin
      dbgen = 1'b1;
    end
    // DEV���� BYPASS_EN=1�̸� ����(���� ��ȸ)
    else if (bypass_en && (lcs == 3'b010)) begin
      dbgen = 1'b1;
    end
    // 3) �������� ��å(deny-first)
    else begin
      if (tzpc == 6'h00)           why_denied[WD_TZPC]        = 1'b1;
      else if (!auth_pass)         why_denied[WD_PK_MISMATCH] = 1'b1;
      else if (lcs == 3'b001)      why_denied[WD_LCS]         = 1'b1; // PRD ����
      else if (domain != 4'd1)     why_denied[WD_DOMAIN]      = 1'b1;
      else if (access_lv < 4'd4)   why_denied[WD_LEVEL]       = 1'b1;
      else                         dbgen = 1'b1; // ��� ���� ���� �� ���� ����
    end
  end
endmodule
