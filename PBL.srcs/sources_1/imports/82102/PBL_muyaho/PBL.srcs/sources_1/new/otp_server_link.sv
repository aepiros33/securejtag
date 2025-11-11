// ============================================================================
// otp_server_link.sv - PMOD 전용 4bit DEVICE (CMDW=2) + PK Dump APB
//   CMD 맵(2b): 01=LCS(3b), 10=PKLS(LSB nibble), 11=SOFT(1b), 00=RESV
//   동작: 첫 sclk 상승엣지에서 헤더 카운트(sclk_cnt==10) 시 CMD 샘플
//         응답 직전 PRETRIG_ADV_CYC 클럭 전에 em_trig_o 펄스 출력
//         이후 otp_dout/otp_ack 응답
// ============================================================================
`timescale 1ns/1ps
module otp_server_link #(
  parameter int CMDW = 2,

  // ================== DELAY / PRE-TRIGGER CONFIG ==================
  parameter int unsigned CLK_HZ               = 100_000_000,
  parameter int unsigned RESP_DELAY_US        = 0,    // 명시 지연(us)
  parameter int unsigned ACK_STRETCH_CYC      = 2,    // ACK 유지 폭
  parameter int unsigned PRETRIG_ADV_CYC      = 20,   // 응답보다 앞선 사전 트리거(클럭)
  parameter int unsigned PRETRIG_STRETCH_CYC  = 300,  // em_trig_o 펄스 폭(클럭) ★가시성↑
  // ================================================================

  // e-fuse contents (mock)
  parameter bit           OTP_SOFTLOCK   = 1'b1,
  parameter logic [2:0]   OTP_LCS        = 3'b010,
  parameter logic [255:0] OTP_PK_ALLOW   = 256'h0123_4567_89AB_CDEF_FEED_FACE_CAFE_BABE_1122_3344_5566_7788_99AA_BBCC_DDEE_FF0F
)(
  input  logic        clk, rst_n,

  // ★ 외부 soft-lock 입력(동기화 가정)
  input  logic        soft_lock_i,

  // PMOD 링크
  input  logic        otp_sclk,       // Host → Dev
  input  logic        otp_req,        // Host → Dev
  input  logic [1:0]  otp_cmd,        // Host → Dev
  output logic        otp_ack,        // Dev  → Host
  output logic [3:0]  otp_dout,       // Dev  → Host

  // ★ EMFI 타이밍용 사전 트리거(계측기/EM 장비 트리거 입력으로 사용)
  output logic        em_trig_o,

  // ★ APB read-only 포트 (PK Dump용)
  input  logic             psel,
  input  logic [7:0]       paddr,     // byte address (0x00~0x1F)
  output logic [31:0]      prdata,
  output logic             pready
);

  // ================== 파생 상수 =================
  localparam int unsigned RESP_DELAY_CYCLES = (CLK_HZ/1_000_000) * RESP_DELAY_US;

  // 실제 응답까지의 지연은 "요청 지연"과 "사전 트리거 여유" 중 큰 값으로 강제
  function automatic [31:0] get_resp_gap();
    automatic int unsigned rdc = RESP_DELAY_CYCLES;
    if (rdc < PRETRIG_ADV_CYC) get_resp_gap = PRETRIG_ADV_CYC;
    else                       get_resp_gap = rdc;
  endfunction
  // =============================================

  // ---------------- fuse source (RO) ----------------
  logic        f_soft;
  logic [2:0]  f_lcs;
  logic [255:0]f_pk;

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      f_soft <= OTP_SOFTLOCK;
      f_lcs  <= OTP_LCS;
      f_pk   <= OTP_PK_ALLOW;
    end else begin
      f_soft <= soft_lock_i;   // 외부 입력 반영
    end
  end

  // ---------------- nibble generator ----------------
  function automatic [3:0] do_cmd (input logic [CMDW-1:0] c);
    case (c)
      2'b01: do_cmd = {1'b0,  f_lcs};    // LCS[2:0]
      2'b10: do_cmd = f_pk[3:0];         // PK LSB nibble
      2'b11: do_cmd = {3'b000, f_soft};  // SOFTLOCK bit0
      default: do_cmd = 4'h0;
    endcase
  endfunction

  // ---------------- PMOD 전용 링크 ----------------
  // 입력 동기화
  logic [2:0] sclk_sync, req_sync;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_sync <= 3'b000; req_sync <= 3'b000;
    end else begin
      sclk_sync <= {sclk_sync[1:0], otp_sclk};
      req_sync  <= {req_sync[1:0],  otp_req };
    end
  end

  wire sclk_rise = (sclk_sync[2:1] == 2'b01);
  wire req_rise  = (req_sync[2:1] == 2'b01);
  wire req_fall  = (req_sync[2:1] == 2'b10);
  wire req_high  =  req_sync[2];

  // 프레임/헤더 래치
  logic        in_frame;
  logic [3:0]  sclk_cnt;
  logic [1:0]  cmd_code_q;

  typedef enum logic [1:0] {IDLE, PENDING, RESPOND} pstate_e;
  pstate_e     pstate;
  logic [31:0] delay_cnt;
  logic [7:0]  ack_cnt;

  // 사전 트리거
  logic        pre_issued;
  logic [15:0] pre_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_frame   <= 1'b0;
      sclk_cnt   <= 4'd0;
      cmd_code_q <= 2'b00;

      otp_dout   <= 4'h0;
      otp_ack    <= 1'b0;

      pstate     <= IDLE;
      delay_cnt  <= '0;
      ack_cnt    <= '0;

      pre_issued <= 1'b0;
      pre_cnt    <= '0;
      em_trig_o  <= 1'b0;
    end else begin
      // 프레임 시작(REQ 상승 or REQ High 상태의 첫 sclk 상승)
      if (!in_frame && (req_rise || (req_high && sclk_rise))) begin
        in_frame <= 1'b1;
        sclk_cnt <= 4'd0;
      end
      // sclk 카운트
      if (in_frame && sclk_rise) begin
        sclk_cnt <= sclk_cnt + 1'b1;
      end
      // 프레임 종료
      if (in_frame && req_fall) begin
        in_frame <= 1'b0;
        sclk_cnt <= 4'd0;
      end

      // ACK stretch
      otp_ack <= (ack_cnt != 0);
      if (ack_cnt != 0) ack_cnt <= ack_cnt - 1'b1;

      // 사전 트리거 펄스 유지
      if (pre_cnt != 0) begin
        pre_cnt   <= pre_cnt - 1'b1;
        em_trig_o <= 1'b1;
      end else begin
        em_trig_o <= 1'b0;
      end

      unique case (pstate)
        IDLE: begin
          // 헤더 타이밍: sclk_cnt == 10에서 CMD 샘플(기존 설계 준수)
          if (in_frame && sclk_rise && (sclk_cnt == 4'd10)) begin
            cmd_code_q <= otp_cmd;
            // ★ off-by-one 제거: gap 그대로 로드
            delay_cnt  <= get_resp_gap();            // 최소 PRETRIG_ADV_CYC 보장
            pre_issued <= 1'b0;
            pstate     <= (get_resp_gap()==0) ? RESPOND : PENDING;
          end
        end

        PENDING: begin
          // 응답 PRETRIG_ADV_CYC 클럭 전에 사전 트리거 1펄스
          if (!pre_issued && (delay_cnt == PRETRIG_ADV_CYC)) begin
            pre_issued <= 1'b1;
            pre_cnt    <= (PRETRIG_STRETCH_CYC==0) ? 16'd1 : PRETRIG_STRETCH_CYC[15:0];
            em_trig_o  <= 1'b1;
          end

          if (delay_cnt != 0) begin
            delay_cnt <= delay_cnt - 1'b1;
          end else begin
            // 응답 생성 시작
            otp_dout <= do_cmd(cmd_code_q);
            otp_ack  <= 1'b1;
            ack_cnt  <= (ACK_STRETCH_CYC==0) ? 8'd1 : ACK_STRETCH_CYC[7:0];
            pstate   <= RESPOND;
          end
        end

        RESPOND: begin
          // ACK 유지 종료 시 IDLE 복귀
          if (ack_cnt == 0) begin
            pstate <= IDLE;
          end
        end
      endcase
    end
  end

  // ========================================================================
  // Read-only PK access window (8×32bit = 256bit)
  //   paddr[4:2] selects word index 0..7 (byte address 기준 0x00~0x1C)
  // ========================================================================
  wire [2:0]   word_sel  = paddr[4:2];
  logic [31:0] pk_words [0:7];

  always_comb begin
    // Split f_pk[255:0] into 8 words (word0 = LSW)
    {pk_words[7], pk_words[6], pk_words[5], pk_words[4],
     pk_words[3], pk_words[2], pk_words[1], pk_words[0]} = f_pk;
    pready = psel;
    if (psel)
      prdata = pk_words[word_sel];
    else
      prdata = 32'h0;
  end

`ifdef TRACE
  always_ff @(posedge clk) begin
    if (in_frame && sclk_rise && (sclk_cnt == 4'd10))
      $display("%t DEV CMD=%b", $time, otp_cmd);
    if (otp_ack) $display("%t DEV ACK=1 DOUT=%h", $time, otp_dout);
    if (em_trig_o) $display("%t DEV EM_TRIG", $time);
  end
`endif

endmodule
