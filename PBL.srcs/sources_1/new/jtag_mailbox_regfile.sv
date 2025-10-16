// jtag_mailbox_regfile.sv  (FINAL)
`timescale 1ns/1ps
module jtag_mailbox_regfile #(
  parameter int AW = 16,

  // ==== OTP 프리로드 상수 (하드코딩) ====
  parameter bit           OTP_SOFTLOCK    = 1'b1,      // 기본 LOCK
  parameter logic [2:0]   OTP_LCS         = 3'b010,    // DEV
  parameter logic [255:0] OTP_PK_ALLOW    = 256'h0123_4567_89AB_CDEF_FEED_FACE_CAFE_BABE_1122_3344_5566_7788_99AA_BBCC_DDEE_FF00,

  // ==== DEV에서만 쓰기 허용 여부(정책 스위치) ====
  parameter bit ALLOW_SOFTLOCK_WRITE_IN_DEV = 1'b1,
  parameter bit ALLOW_LCS_WRITE_IN_DEV      = 1'b1,
  parameter bit ALLOW_PK_WRITE_IN_DEV       = 1'b1
)(
  input  logic             clk, rst_n,
  
  // Simple reg bus (1-cycle write, 1-cycle read-valid)
  input  logic             bus_cs,
  input  logic             bus_we,       // 1=write, 0=read
  input  logic [AW-1:0]    bus_addr,
  input  logic [31:0]      bus_wdata,
  output logic [31:0]      bus_rdata,
  output logic             bus_rvalid,

  // Inputs from other blocks (RO mirrors / status)
  output logic [2:0]       lcs_o,        // SFR에서 나감
  input  logic             dbgen_i,      // 세션 래치된 DBGEN 미러
  input  logic             pk_match_i,
  input  logic             sig_valid_i,  // MVP: 1
  input  logic             auth_pass_i,  // final decision (policy)
  input  logic [7:0]       why_denied_i,
  // NEW: expose auth FSM progress
  input  logic             busy_i,
  input  logic             done_i,

  // Outputs to other blocks (RW cfg / WO payload / pulses)
  output logic [5:0]       tzpc_o,
  output logic [3:0]       domain_o,
  output logic [3:0]       access_lv_o,
  output logic [255:0]     pk_in_o,
  output logic [255:0]     pk_allow_shadow_o,
  output logic             auth_start_pulse,
  output logic             reset_fsm_pulse,
  output logic             debug_done_pulse,
  output logic             soft_lock_o,
  output logic             bypass_en_o,     // ★ 추가: BYPASS_EN 노출
    // Added: OTP soft-lock read handshake from otp_client_apb
  input  logic        otp_read_soft_done,
  input  logic        otp_read_soft_val
);

  import secure_jtag_pkg::*;
  `include "secure_jtag_cmd_defs.svh"

  // ------------------ internal regs ------------------
  logic [31:0] pk_in  [0:7];   // WO: read-as-zero
  logic [31:0] pk_ref [0:7];   // RW: shadow (SFR, OTP 프리로드)

  logic [31:0] tzpc_r, domain_r, access_lv_r;
  logic [31:0] why_r;          // transactional WHY (latched at DONE)

  // pulses
  logic auth_start_d, reset_fsm_d, debug_done_d;
  logic done_sticky;           // latch DONE to avoid 1-cycle pulse miss

  // SFR: LCS / SOFTLOCK / BYPASS_EN
  logic [31:0] lcs_r;          // [2:0] 사용
  logic        soft_lock_r;
  logic        bypass_en_r;    // ★

  // defaults (power-on)
  localparam logic [31:0] TZPC_DEF      = 32'h0000_003F;
  localparam logic [31:0] DOMAIN_DEF    = 32'h0000_0001;
  localparam logic [31:0] ACCESS_LV_DEF = 32'h0000_0004;

  localparam logic [AW-1:0] ADDR_CMD_L  = ADDR_CMD[AW-1:0];

  // pack outs
  assign tzpc_o            = tzpc_r[5:0];
  assign domain_o          = domain_r[3:0];
  assign access_lv_o       = access_lv_r[3:0];
  assign pk_in_o           = {pk_in[7],pk_in[6],pk_in[5],pk_in[4],pk_in[3],pk_in[2],pk_in[1],pk_in[0]};
  assign pk_allow_shadow_o = {pk_ref[7],pk_ref[6],pk_ref[5],pk_ref[4],pk_ref[3],pk_ref[2],pk_ref[1],pk_ref[0]};

  // pulses
  assign auth_start_pulse = auth_start_d;
  assign reset_fsm_pulse  = reset_fsm_d;
  assign debug_done_pulse = debug_done_d;

  // SFR exports
  assign lcs_o        = lcs_r[2:0];
  assign soft_lock_o  = soft_lock_r;
  assign bypass_en_o  = bypass_en_r; // ★

  // ------------------ helpers ------------------
  function automatic bit is_pk_in_addr(input logic [AW-1:0] a, output int idx);
    idx = (a - ADDR_PK_IN0) >> 2;
    return (a >= ADDR_PK_IN0) && (a < (ADDR_PK_IN0 + 8*4)) && (a[1:0] == 2'b00);
  endfunction

  function automatic bit is_pk_allow_addr(input logic [AW-1:0] a, output int idx);
    idx = (a - ADDR_PK_ALLOW0) >> 2;
    return (a >= ADDR_PK_ALLOW0) && (a < (ADDR_PK_ALLOW0 + 8*4)) && (a[1:0] == 2'b00);
  endfunction

  function automatic bit is_dev();
    return (lcs_r[2:0] == 3'b010);
  endfunction

  // ------------------ decoded CMD hits ------------------
  wire cmd_write_hit  = (bus_cs && bus_we && (bus_addr == ADDR_CMD_L));
  wire start_hit      = cmd_write_hit && ((bus_wdata & `CMD_START_MASK)      != 32'h0);
  wire reset_hit      = cmd_write_hit && ((bus_wdata & `CMD_RESET_FSM_MASK)  != 32'h0);
  wire debug_done_hit = cmd_write_hit && ((bus_wdata & `CMD_DEBUG_DONE_MASK) != 32'h0);

  // ------------------ write path ------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      tzpc_r       <= TZPC_DEF;
      domain_r     <= DOMAIN_DEF;
      access_lv_r  <= ACCESS_LV_DEF;
      done_sticky  <= 1'b0;

      // OTP 프리로드 → SFR
      soft_lock_r  <= 1'b0;   // ← 안전 기본값: 1=(디버그ON). OTP 읽히면 갱신됨.
      lcs_r        <= {29'h0, OTP_LCS};
      bypass_en_r  <= 1'b0;              // ★ reset=0

      for (int i=0;i<8;i++) begin
        pk_in[i]  <= '0;
        // OTP 256b를 32b 조각으로 섀도우에 복사(LSW→MSW)
        pk_ref[i] <= OTP_PK_ALLOW[32*i +: 32];
      end

      auth_start_d <= 1'b0;
      reset_fsm_d  <= 1'b0;
      debug_done_d <= 1'b0;
      why_r        <= '0;
    end else begin
      // default: deassert pulses
      auth_start_d <= 1'b0;
      reset_fsm_d  <= 1'b0;
      debug_done_d <= 1'b0;

      // WHY: START/RESET 때 0, DONE에서 최종값 캡처
      if (start_hit || reset_hit) begin
        why_r <= 32'h0;
      end else if (done_i) begin
        `ifndef SYNTHESIS
          if (!$isunknown(why_denied_i)) why_r <= {24'h0, why_denied_i};
        `else
          why_r <= {24'h0, why_denied_i};
        `endif
      end

      // DONE sticky
      if (done_i) done_sticky <= 1'b1;

      // --- CMD: mask-based one-shot pulses ---
      if (start_hit)     begin auth_start_d <= 1'b1; done_sticky <= 1'b0; end
      if (reset_hit)     begin reset_fsm_d  <= 1'b1; done_sticky <= 1'b0; end
      if (debug_done_hit)      debug_done_d <= 1'b1; // 세션 종료 트리거

      // --- regular register writes ---
      if (bus_cs && bus_we) begin
        int idx;
        unique case (bus_addr)
          ADDR_CMD: begin
`ifdef LOGGING
  `ifndef SYNTHESIS
            if (start_hit || reset_hit || debug_done_hit)
              $display("RF CMD @%0t wdata=%h (start=%0d reset=%0d dbgdone=%0d)",
                       $time, bus_wdata, start_hit, reset_hit, debug_done_hit);
  `endif
`endif
          end
          ADDR_TZPC:       tzpc_r      <= bus_wdata;
          ADDR_DOMAIN:     domain_r    <= bus_wdata;
          ADDR_ACCESS_LV:  access_lv_r <= bus_wdata;

          // DEV에서만 쓰기 허용(정책 스위치 적용)
          ADDR_LCS: begin
            if (ALLOW_LCS_WRITE_IN_DEV && is_dev())
              lcs_r <= {29'h0, bus_wdata[2:0]};
          end
          ADDR_SOFTLOCK: begin
            if (ALLOW_SOFTLOCK_WRITE_IN_DEV && is_dev())
              soft_lock_r <= bus_wdata[0];
          end
          // ★ BYPASS_EN: (원하면 DEV에서만 허용하도록 is_dev() 조건 추가)
          ADDR_BYPASS_EN: begin
            bypass_en_r <= bus_wdata[0];
          end

          default: begin
            if (is_pk_in_addr(bus_addr, idx)) begin
              pk_in[idx] <= bus_wdata;       // WO storage (reads return zero)
            end else
            if (is_pk_allow_addr(bus_addr, idx)) begin
              if (ALLOW_PK_WRITE_IN_DEV && is_dev())
                pk_ref[idx] <= bus_wdata;    // DEV에서만 수정 허용
            end
          end
        endcase
      end
    // [CHANGE #2] capture OTP soft-lock when READ_SOFT completes
    if (otp_read_soft_done) begin
      soft_lock_r <= otp_read_soft_val;
    end
    end
  end

  // ------------------ read path ------------------
  logic [31:0] rdata_q;
  always_comb begin
    rdata_q = '0;
    unique case (bus_addr)
      ADDR_CMD:       rdata_q = 32'h0; // WO
      ADDR_STATUS: begin
        logic [31:0] s;
        s = '0;
        s[ST_BUSY]      = busy_i;                       // reflect FSM BUSY
        s[ST_DONE]      = (done_i | done_sticky);       // pulse OR sticky
        s[ST_PK_MATCH]  = pk_match_i;
        s[ST_SIG_VALID] = sig_valid_i;
        s[ST_AUTH_PASS] = auth_pass_i;
        s[ST_DBGEN]     = dbgen_i;                      // 세션 래치 미러
        rdata_q = s;
      end
      // PK_IN[*] are WO - read-as-zero
      ADDR_TZPC:       rdata_q = tzpc_r;
      ADDR_DOMAIN:     rdata_q = domain_r;
      ADDR_ACCESS_LV:  rdata_q = access_lv_r;
      ADDR_WHY_DENIED: rdata_q = why_r;                 // transactional WHY(guarded)
      ADDR_SOFTLOCK:   rdata_q = {31'h0, soft_lock_r};
      ADDR_BYPASS_EN:  rdata_q = {31'h0, bypass_en_r};  // ★
      ADDR_LCS:        rdata_q = {29'h0, lcs_r[2:0]};
      // NEW: 보호 레지스터 (필터 밖 주소)
      ADDR_PROT:       rdata_q = 32'hABCD_1234;
      default: begin
        int idx;
        if (is_pk_allow_addr(bus_addr, idx))
          rdata_q = pk_ref[idx];                        // RW shadow
        // else keep zero (PK_IN = WO)
      end
    endcase
  end

  // simple 1-cycle read valid
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      bus_rvalid <= 1'b0;
    end else begin
      bus_rvalid <= (bus_cs & ~bus_we);
    end
  end
  assign bus_rdata = rdata_q;

endmodule
