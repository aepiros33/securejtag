// ============================================================================
// auth_fsm_pk4.sv  --  OTP 4bit 기반 인증 FSM (단일 샘플 버전: 다수결 제거)
//   - START 시퀀스: SOFT(00) 1회 → (옵션) LCS(01) 1회 → PKLS(10) 1회
//   - 비교: PK_IN[3:0] vs PKLS → pk_match/pass/why_denied
//   - otp_client_apb 의 외부 명령 주입 포트(ext_*)와 직접 핸드셰이크
//   - busy/done/pk_match/pass/why_denied 은 regfile/status에 그대로 연결
// ============================================================================
`timescale 1ns/1ps
module auth_fsm_pk4 #(
  parameter int PKW       = 256,
  parameter bit READ_LCS  = 1'b1   // 1이면 LCS도 1회 읽어 노출
)(
  input  logic              clk,
  input  logic              rst_n,

  // 트리거/클리어
  input  logic              start,
  input  logic              clear,

  // PK 입력 (LSB 4비트만 사용)
  input  logic [PKW-1:0]    pk_input,
  input  logic [PKW-1:0]    pk_allow, // 호환용(미사용)

  // otp_client_apb 외부 명령 주입 인터페이스
  output logic              ext_cmd_fire,
  output logic [1:0]        ext_cmd_code,   // 00=SOFT, 01=LCS, 10=PKLS
  input  logic              ext_busy,
  input  logic              ext_done,       // 1클럭 펄스
  input  logic [3:0]        ext_data_nib,   // DONE 시점의 니블

  // 상태/결과
  output logic              busy,
  output logic              done,           // 1클럭 펄스
  output logic              pk_match,
  output logic              pass,

  // OTP에서 읽은 값 노출(정책/디버그용)
  output logic              soft_bit,
  output logic [2:0]        lcs_bits,

  // WHY 코드(예: 0x08 = PK_MISMATCH)
  output logic [7:0]        why_denied
);

  typedef enum logic [3:0] {
    S_IDLE      = 4'd0,
    S_SOFT_ISS  = 4'd1,
    S_SOFT_WAIT = 4'd2,
    S_LCS_ISS   = 4'd3,
    S_LCS_WAIT  = 4'd4,
    S_PKLS_ISS  = 4'd5,
    S_PKLS_WAIT = 4'd6,
    S_EVAL      = 4'd7,
    S_DONE      = 4'd8
  } st_e;

  st_e st, nx;

  // 래치
  logic [2:0] lcs_q;
  logic [3:0] pkls_q;

  // 기본/리셋
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      st <= S_IDLE;
      busy <= 1'b0;
      done <= 1'b0;
      pk_match <= 1'b0;
      pass <= 1'b0;
      why_denied <= 8'h00;
      soft_bit <= 1'b1; // 안전측(잠금) 기본
      lcs_q <= 3'b000;
      pkls_q <= 4'h0;
      ext_cmd_fire <= 1'b0;
      ext_cmd_code <= 2'b00;
    end else begin
      // 기본 클리어
      done         <= 1'b0;
      ext_cmd_fire <= 1'b0;

      // CLEAR
      if (clear) begin
        st <= S_IDLE;
        busy <= 1'b0;
        pass <= 1'b0;
        pk_match <= 1'b0;
        why_denied <= 8'h00;
      end else begin
        st <= nx;

        unique case (st)
          S_IDLE: begin
            if (start) begin
              busy <= 1'b1;
            end
          end

          // SOFT 한 번만 읽기
          S_SOFT_ISS: begin
            ext_cmd_code <= 2'b00;
            ext_cmd_fire <= 1'b1;   // 1클럭 펄스
          end
          S_SOFT_WAIT: begin
            if (ext_done) begin
              soft_bit <= ext_data_nib[0];
            end
          end

          // (옵션) LCS 한 번 읽기
          S_LCS_ISS: begin
            ext_cmd_code <= 2'b01;
            ext_cmd_fire <= 1'b1;
          end
          S_LCS_WAIT: begin
            if (ext_done) begin
              lcs_q <= ext_data_nib[2:0];
            end
          end

          // PKLS 한 번 읽기
          S_PKLS_ISS: begin
            ext_cmd_code <= 2'b10;
            ext_cmd_fire <= 1'b1;
          end
          S_PKLS_WAIT: begin
            if (ext_done) begin
              pkls_q <= ext_data_nib[3:0];
            end
          end

          S_EVAL: begin
            pk_match   <= (pk_input[3:0] == pkls_q);
            pass       <= (pk_input[3:0] == pkls_q);
            why_denied <= (pk_input[3:0] == pkls_q) ? 8'h00 : 8'h08; // PK_MISMATCH
          end

          S_DONE: begin
            done <= 1'b1;   // 1클럭 펄스
            busy <= 1'b0;
          end
        endcase
      end
    end
  end

  assign lcs_bits = lcs_q;

  // next-state
  always_comb begin
    nx = st;
    unique case (st)
      S_IDLE      : nx = (start) ? S_SOFT_ISS : S_IDLE;

      S_SOFT_ISS  : nx = S_SOFT_WAIT;
      S_SOFT_WAIT : nx = (ext_done) ? (READ_LCS ? S_LCS_ISS : S_PKLS_ISS) : S_SOFT_WAIT;

      S_LCS_ISS   : nx = S_LCS_WAIT;
      S_LCS_WAIT  : nx = (ext_done) ? S_PKLS_ISS : S_LCS_WAIT;

      S_PKLS_ISS  : nx = S_PKLS_WAIT;
      S_PKLS_WAIT : nx = (ext_done) ? S_EVAL : S_PKLS_WAIT;

      S_EVAL      : nx = S_DONE;
      S_DONE      : nx = S_IDLE;
      default     : nx = S_IDLE;
    endcase
  end

endmodule
