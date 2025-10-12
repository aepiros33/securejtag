`timescale 1ns/1ps
module access_policy (
  input  logic        soft_lock,          // 0: BYPASS
  input  logic [2:0]  lcs,                // one-hot {PRD, DEV, RMA}
  input  logic [5:0]  tzpc,
  input  logic [3:0]  domain,
  input  logic [3:0]  access_lv,
  input  logic        auth_pass,          // from auth FSM
  output logic        dbgen,              // final debug enable (raw)
  output logic [7:0]  why_denied          // reason bits
);
  import secure_jtag_pkg::*;

  always_comb begin
    dbgen      = 1'b0;
    why_denied = '0;

    if (!soft_lock) begin
      // BYPASS: 인증/정책 미적용
      dbgen      = 1'b1;
      why_denied = '0;
    end else begin
      // LOCK: 정책 평가 (deny-first)
      if (tzpc == 6'h00) begin
        why_denied[WD_TZPC] = 1'b1;
      end
      else if (!auth_pass) begin
        why_denied[WD_PK_MISMATCH] = 1'b1;
      end
      else if (lcs == 3'b001) begin
        // PRD만 차단(DEV=010, RMA=100 허용). 필요시 매핑 변경 가능
        why_denied[WD_LCS] = 1'b1;
      end
      else if (domain != 4'd1) begin
        // MVP: domain==1만 허용(간단 룰)
        why_denied[WD_DOMAIN] = 1'b1;
      end
      else if (access_lv < 4'd4) begin
        // MVP: level>=4만 허용
        why_denied[WD_LEVEL] = 1'b1;
      end
      else begin
        dbgen = 1'b1; // 모든 조건 통과
      end
    end
  end
endmodule
