// ============================================================================
// otp_server_link.sv - 4bit DEVICE (CMDW=2, loopback/PMOD 공용)
//   ? CMDW=2 맵(기본): 00=SOFT(=1), 01=LCS(=2), 10=PKLS(LSB), 11=RESV
//   ? loopback: 응답 1클럭 지연 + data_valid 2클럭 유지 (보드에서 확실히 잡힘)
//   ? PMOD 분기: 예시(실전은 CMD 수신 FSM 권장)
//   ? 파라미터 OTP_* 로 e-fuse(모의) 값을 설정
// ============================================================================

`timescale 1ns/1ps
module otp_server_link #(
  parameter int CMDW     = 2,
  parameter bit USE_PMOD = 1'b0,
  // e-fuse contents (mock)
  parameter bit           OTP_SOFTLOCK   = 1'b1,
  parameter logic [2:0]   OTP_LCS        = 3'b010,
  parameter logic [255:0] OTP_PK_ALLOW   = 256'h0123_4567_89AB_CDEF_FEED_FACE_CAFE_BABE_1122_3344_5566_7788_99AA_BBCC_DDEE_FF00
)(
  input  logic        clk, rst_n,

  // PMOD 링크 (USE_PMOD=1 일 때 사용)
  input  logic        otp_sclk,
  input  logic        otp_req,
  output logic        otp_ack,
  output logic [3:0]  otp_dout,

  // 루프백(싱글보드) 모드 입력
  input  logic             cmd_valid,
  input  logic [CMDW-1:0]  cmd_code,
  output logic             data_valid,
  output logic [3:0]       data_nib
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
      2'b10: do_cmd = f_pk[3:0];         // PK LSB nibble
      default: do_cmd = 4'h0;
    endcase
  endfunction

  // ---------------- Loopback (USE_PMOD=0) ----------
  generate if (!USE_PMOD) begin : g_loop
    // 한 클럭 지연 + data_valid 2클럭 유지
    logic             cmd_v_q;
    logic [CMDW-1:0]  cmd_c_q;
    logic [1:0]       dv_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        cmd_v_q<=1'b0; cmd_c_q<='0;
        data_valid<=1'b0; data_nib<=4'h0; dv_cnt<=2'd0;
      end else begin
        // 1클럭 지연 파이프라인
        cmd_v_q <= cmd_valid;
        if (cmd_valid) cmd_c_q <= cmd_code;

        // data_valid 2클럭 유지(현재+다음)
        if (dv_cnt != 2'd0) begin
          dv_cnt     <= dv_cnt - 1'b1;
          data_valid <= 1'b1;
        end else begin
          data_valid <= 1'b0;
          if (cmd_v_q) begin
            data_nib   <= do_cmd(cmd_c_q);
            data_valid <= 1'b1;
            dv_cnt     <= 2'd1;
          end
        end
      end
    end

    assign otp_ack  = 1'b0;
    assign otp_dout = 4'h0;

  end else begin : g_pmod
  // ---------------- PMOD (USE_PMOD=1) ---------------
    typedef enum logic [1:0] {S_IDLE,S_ACK1,S_ACK0} se;
    se st, nx;
    always_ff @(posedge otp_sclk or negedge rst_n) begin
      if(!rst_n) begin
        st<=S_IDLE; otp_ack<=1'b0; otp_dout<=4'h0;
      end else begin
        st<=nx;
        case(st)
          S_IDLE: begin
            otp_ack <= 1'b0;
            if (otp_req) begin
              // (예시) 고정 응답 - 실제 구현은 CMD 수신 FSM으로 교체
              otp_dout <= do_cmd(2'b00); // SOFT
            end
          end
          S_ACK1: begin otp_ack<=1'b1; end
          S_ACK0: begin otp_ack<=1'b0; end
        endcase
      end
    end
    assign data_valid = 1'b0;
    assign data_nib   = 4'h0;
  end endgenerate

`ifdef TRACE
  always_ff @(posedge clk) begin
    if (cmd_valid)  $display("%t DEV CMD=%b", $time, cmd_code);
    if (data_valid) $display("%t DEV DATA_NIB=%h", $time, data_nib);
  end
`endif

endmodule
