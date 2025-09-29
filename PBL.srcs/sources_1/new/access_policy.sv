// access_policy.sv  (FINAL, BYPASS 경로 포함)
`timescale 1ns/1ps
module access_policy (
  input  logic        soft_lock,          // 0이면 BYPASS(세션 오픈)
  input  logic [2:0]  lcs,                // DEV=3'b010 가정
  input  logic [5:0]  tzpc,
  input  logic [3:0]  domain,
  input  logic [3:0]  access_lv,
  input  logic        auth_pass,          // from auth FSM (PK/SIG 검증 OK)
  input  logic        bypass_en,          // ★ BYPASS_EN (SFR에서)
  output logic        dbgen,              // final debug enable (session_open)
  output logic [7:0]  why_denied          // reason bits (옵션)
);
  import secure_jtag_pkg::*;

  always_comb begin
    dbgen      = 1'b0;
    why_denied = '0;

    // 1) 소프트락 해제 ⇒ 무조건 오픈
    if (!soft_lock) begin
      dbgen = 1'b1;
    end
    // 2) DEV + BYPASS_EN=1 ⇒ 오픈
    else if (bypass_en && (lcs == 3'b010)) begin
      dbgen = 1'b1;
    end
    // 3) 나머지는 정책(deny-first)
    else begin
      if (tzpc == 6'h00)           why_denied[WD_TZPC]        = 1'b1;
      else if (!auth_pass)         why_denied[WD_PK_MISMATCH] = 1'b1;
      else if (lcs == 3'b001)      why_denied[WD_LCS]         = 1'b1; // PRD 제한
      else if (domain != 4'd1)     why_denied[WD_DOMAIN]      = 1'b1;
      else if (access_lv < 4'd4)   why_denied[WD_LEVEL]       = 1'b1;
      else                         dbgen = 1'b1; // 모든 조건 충족 → 세션 오픈
    end
  end
endmodule
