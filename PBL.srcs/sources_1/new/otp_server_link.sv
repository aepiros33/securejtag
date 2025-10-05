// ============================================================================
// otp_server_link.sv  (CMDW=2, loopback/PMOD 공용 + debug taps)
//  - Loopback: 응답 1클럭 지연 + data_valid 2클럭 유지
//  - Debug taps: dev_cmd_seen, dev_cmd_code_q, dev_data_valid, dev_data_nib, dev_dv_cnt
// ============================================================================

`timescale 1ns/1ps
module otp_server_link #(
  parameter int CMDW     = 2,
  parameter bit USE_PMOD = 1'b0,
  // e-fuse contents
  parameter bit           OTP_SOFTLOCK   = 1'b1,
  parameter logic [2:0]   OTP_LCS        = 3'b010,
  parameter logic [255:0] OTP_PK_ALLOW   = 256'h0123_4567_89AB_CDEF_FEED_FACE_CAFE_BABE_1122_3344_5566_7788_99AA_BBCC_DDEE_FF00
)(
  input  logic        clk, rst_n,

  // PMOD 링크 (USE_PMOD=1일 때 사용)
  input  logic        otp_sclk,
  input  logic        otp_req,
  output logic        otp_ack,
  output logic [3:0]  otp_dout,

  // 루프백(싱글보드) 모드 입력
  input  logic             cmd_valid,
  input  logic [CMDW-1:0]  cmd_code,
  output logic             data_valid,
  output logic [3:0]       data_nib,

  // ---- Debug taps to client ----
  output logic             dev_cmd_seen,      // pipelined cmd_valid
  output logic [CMDW-1:0]  dev_cmd_code_q,    // captured command
  output logic             dev_data_valid,    // equals data_valid
  output logic [3:0]       dev_data_nib,      // equals data_nib
  output logic [1:0]       dev_dv_cnt         // internal stretch counter
);

  // ---------------- fuse source (RO) ----------------
  logic        f_soft;
  logic [2:0]  f_lcs;
  logic [255:0]f_pk;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      f_soft <= OTP_SOFTLOCK;
      f_lcs  <= OTP_LCS;
      f_pk   <= OTP_PK_ALLOW;
    end
  end

  // ---------------- nibble generator ----------------
  function automatic [3:0] do_cmd (input logic [CMDW-1:0] c);
    case (c)
      2'b00: do_cmd = {3'b000, f_soft};  // SOFTLOCK bit0 (1)
      2'b01: do_cmd = {1'b0,  f_lcs};    // LCS[2:0] (2)
      2'b10: do_cmd = f_pk[3:0];         // PK LSB nibble (기본 0)
      default: do_cmd = 4'h0;
    endcase
  endfunction

  // ---------------- Loopback (USE_PMOD=0) ----------
  generate if (!USE_PMOD) begin : g_loop
    logic             cmd_v_q;
    logic [CMDW-1:0]  cmd_c_q;
    logic [1:0]       dv_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        cmd_v_q<=1'b0; cmd_c_q<='0;
        data_valid<=1'b0; data_nib<=4'h0; dv_cnt<=2'd0;
      end else begin
        // pipeline
        cmd_v_q <= cmd_valid;
        if (cmd_valid) cmd_c_q <= cmd_code;

        // dv stretch
        if (dv_cnt != 2'd0) begin
          dv_cnt     <= dv_cnt - 1'b1;
          data_valid <= 1'b1;
        end else begin
          data_valid <= 1'b0;
          if (cmd_v_q) begin
            data_nib   <= do_cmd(cmd_c_q);
            data_valid <= 1'b1;
            dv_cnt     <= 2'd1;   // 현재+다음 총 2클럭
          end
        end
      end
    end

    // debug taps
    assign dev_cmd_seen   = cmd_v_q;
    assign dev_cmd_code_q = cmd_c_q;
    assign dev_data_valid = data_valid;
    assign dev_data_nib   = data_nib;
    assign dev_dv_cnt     = dv_cnt;

    assign otp_ack  = 1'b0;
    assign otp_dout = 4'h0;

  end else begin : g_pmod
    // (생략) PMOD 모드 예시 FSM
    assign data_valid = 1'b0;
    assign data_nib   = 4'h0;
    assign dev_cmd_seen   = 1'b0;
    assign dev_cmd_code_q = '0;
    assign dev_data_valid = 1'b0;
    assign dev_data_nib   = 4'h0;
    assign dev_dv_cnt     = 2'b00;
    always_ff @(posedge otp_sclk or negedge rst_n) begin
      if(!rst_n) begin otp_ack<=1'b0; otp_dout<=4'h0; end
      else begin otp_ack<=1'b0; otp_dout<=do_cmd(2'b00); end
    end
  end endgenerate

endmodule
