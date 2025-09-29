`timescale 1ns/1ps
module top_secure_jtag_with_auth (
  input  logic         clk, rst_n,
  // temporary simple reg bus
  input  logic         cs,
  input  logic         we,
  input  logic [15:0]  addr,
  input  logic [31:0]  wdata,
  output logic [31:0]  rdata,
  output logic         rvalid,
  // expose DBGEN to DAP
  output logic         dbg_enable_o
);
  import secure_jtag_pkg::*;


  // ---------------- REGFILE/정책/인증 배선 ----------------
  // regfile → 상위
  wire        soft_lock;                 // regfile soft_lock_o
  wire [2:0]  lcs;                       // regfile lcs_o
  logic [5:0]   tzpc;
  logic [3:0]   domain, access_lv;
  logic [255:0] pk_in, pk_ref;           // pk_ref = regfile shadow
  logic         auth_start, reset_fsm, debug_done_pulse;

  // 상태/정책
  logic        pk_match_i, sig_valid_i, auth_pass_i;
  logic [7:0]  why_i;
  logic        busy_w, done_w;
  wire         dbgen_raw;                // access_policy raw result
  logic        dbg_session_en;           // 최종 DBGEN 세션 래치
  
  // ---------------- OTP 컨트롤 ----------------
  logic        soft_lock_otp;
  logic [2:0]  lcs_otp;
  logic [255:0]pk_allow_otp;

  otp_ctrl u_otp (
    .clk, .rst_n,
    .soft_lock_fuse_o(soft_lock_otp),
    .lcs_fuse_o     (lcs_otp),
    .pk_allow_fuse_o(pk_allow_otp)
  );

  // ---------------- Pre-auth 필터 (이미 쓰고 있다면 그대로) ----------------
  // 외부 버스 → 필터 → regfile
  logic        cs_f, we_f;
  logic [15:0] addr_f;
  logic [31:0] wdata_f, rdata_rf;
  logic        rvalid_rf;

  regbus_filter_prepost #(
    .AW(16),
    .PRE_LOW (PRE_ALLOW_LOW),
    .PRE_HIGH(PRE_ALLOW_HIGH)
  ) u_flt (
    .clk, .rst_n,
    .cs_in(cs), .we_in(we), .addr_in(addr), .wdata_in(wdata),
    .cs_out(cs_f), .we_out(we_f), .addr_out(addr_f), .wdata_out(wdata_f),
    .rdata_in(rdata_rf), .rvalid_in(rvalid_rf),
    .rdata_out(rdata), .rvalid_out(rvalid),
    .soft_lock(soft_lock),              // << OTP/REG MUX 반영
    .session_open(dbg_session_en)
  );

  // ---------------- REGFILE ----------------
  jtag_mailbox_regfile u_reg (
    .clk, .rst_n,
    .bus_cs(cs_f), .bus_we(we_f), .bus_addr(addr_f), .bus_wdata(wdata_f),
    .bus_rdata(rdata_rf), .bus_rvalid(rvalid_rf),

    .lcs_o(lcs), .dbgen_i(dbg_session_en),
    .pk_match_i(pk_match_i), .sig_valid_i(sig_valid_i),
    .auth_pass_i(auth_pass_i), .why_denied_i(why_i),

    .busy_i(busy_w), .done_i(done_w),

    .tzpc_o(tzpc), .domain_o(domain), .access_lv_o(access_lv),
    .pk_in_o(pk_in), .pk_allow_shadow_o(pk_ref),

    .auth_start_pulse(auth_start),
    .reset_fsm_pulse(reset_fsm),
    .debug_done_pulse(debug_done_pulse),
    .soft_lock_o(soft_lock)
  );

  // ---------------- AUTH FSM ----------------
  wire auth_start_g = auth_start & soft_lock;  // << soft_lock 사용

  auth_fsm_plain u_auth (
    .clk, .rst_n,
    .start(auth_start_g),
    .clear(reset_fsm),
    .pk_input(pk_in),
    .pk_allow(pk_ref),                // << OTP/REG MUX 반영
    .busy(busy_w), .done(done_w),
    .pk_match(pk_match_i),
    .pass(auth_pass_i)
  );

  // ---------------- 정책 ----------------
  access_policy u_pol (
    .soft_lock(soft_lock),              // << OTP/REG MUX 반영
    .lcs(lcs),                          // << OTP/REG MUX 반영
    .tzpc(tzpc),
    .domain(domain),
    .access_lv(access_lv),
    .auth_pass(auth_pass_i),
    .dbgen(dbgen_raw),
    .why_denied(why_i)
  );

  // ---------------- 세션 래치 ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_session_en <= 1'b0;
    end else begin
      if (!soft_lock) begin
        // BYPASS 모드: 항상 열림
        dbg_session_en <= 1'b1;
      end else begin
        // PASS 직후 오픈
        if (done_w && dbgen_raw)
          dbg_session_en <= 1'b1;
        // 사용자가 DEBUG_DONE 명령 쓰면 닫힘
        if (debug_done_pulse)
          dbg_session_en <= 1'b0;
      end
    end
  end

  // 최종 DAP enable은 세션 래치
  assign dbg_enable_o = dbg_session_en;

  // ---------------- DAP/AP 스텁 (가시성) ----------------
  logic dp_active, ap_ready;

  dp_wrapper_stub u_dp (
    .clk, .rst_n,
    .dbg_enable_i(dbg_enable_o),
    .dp_active_o (dp_active)
  );

  ap_bridge_stub u_ap (
    .clk, .rst_n,
    .en_i      (dp_active),
    .ap_ready_o(ap_ready)
  );

endmodule
