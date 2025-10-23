// ============================================================================
// otp_server_link.sv - 4bit DEVICE (CMDW=2, loopback/PMOD ���� + PK Dump APB)
//   ? CMDW=2 ��: 01=LCS(=2), 10=PKLS(LSB), 11=SOFT(=1), 00=RESV
//   ? loopback: ���� 1Ŭ�� ���� + data_valid 2Ŭ�� ���� (+���� ����)
//   ? PMOD: ù sclk ��¿������� CMD(2bit) ���� �� do_cmd() ���� (+���� ����)
//   ? APB: f_pk[255:0] ��ü�� �б� ���� ���� (8��32bit, 0x00~0x1C)
// ============================================================================

`timescale 1ns/1ps
module otp_server_link #(
  parameter int CMDW     = 2,
  parameter bit USE_PMOD = 1'b0,

  // ================== DELAY PATCH (config) ==================
  parameter int unsigned CLK_HZ          = 100_000_000,   // ���� Ŭ�� (Hz)
  parameter int unsigned RESP_DELAY_US   = 1000,          // ���� ����(us) �⺻ 1ms
  parameter int unsigned ACK_STRETCH_CYC = 2,             // ACK ���� Ŭ�� ��
  // ==========================================================

  // e-fuse contents (mock)
  parameter bit           OTP_SOFTLOCK   = 1'b1,
  parameter logic [2:0]   OTP_LCS        = 3'b010,
  parameter logic [255:0] OTP_PK_ALLOW   = 256'h0123_4567_89AB_CDEF_FEED_FACE_CAFE_BABE_1122_3344_5566_7788_99AA_BBCC_DDEE_FF0F
)(
  input  logic        clk, rst_n,
  // �� �߰�: �ܺο��� �ִ� soft-lock �Է�
  input  logic        soft_lock_i,
  // PMOD ��ũ (USE_PMOD=1 �� �� ���)
  input  logic        otp_sclk,       // Host �� Dev
  input  logic        otp_req,        // Host �� Dev
  input  logic [1:0]  otp_cmd,        // Host �� Dev
  output logic        otp_ack,        // Dev  �� Host
  output logic [3:0]  otp_dout,       // Dev  �� Host

  // ������(�̱ۺ���) ��� �Է�
  input  logic             cmd_valid,
  input  logic [CMDW-1:0]  cmd_code,
  output logic             data_valid,
  output logic [3:0]       data_nib,

  // �� APB read-only ��Ʈ (PK Dump��)
  input  logic             psel,
  input  logic [7:0]       paddr,     // byte address (0x00~0x1F)
  output logic [31:0]      prdata,
  output logic             pready
);

  // ================== DELAY PATCH (derived) =================
  // RESP_DELAY_CYCLES: ������ ������ Ŭ�� �� (0�̸� ��� ����)
  localparam int unsigned RESP_DELAY_CYCLES =
      (CLK_HZ/1_000_000) * RESP_DELAY_US;
  // ==========================================================

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
      f_soft <= soft_lock_i;   // �� ����ġ(����ȭ��) �� �ݿ�
    end
  end

  // ---------------- nibble generator ----------------
  function automatic [3:0] do_cmd (input logic [CMDW-1:0] c);
    case (c)
      2'b01: do_cmd = {1'b0,  f_lcs};    // LCS[2:0]
      2'b10: do_cmd = f_pk[3:0];         // PK LSB nibble
      2'b11: do_cmd = {3'b000, f_soft};  // SOFTLOCK bit0 (1)
      default: do_cmd = 4'h0;
    endcase
  endfunction

  // ---------------- Loopback (USE_PMOD=0) ----------
  generate if (!USE_PMOD) begin : g_loop
    // �� Ŭ�� ���� + data_valid 2Ŭ�� ���� (+ ���� ���� �߰�)
    logic             cmd_v_q;
    logic [CMDW-1:0]  cmd_c_q;
    logic [1:0]       dv_cnt;

    // ===== DELAY PATCH (loopback) =====
    logic        pending;
    logic [31:0] delay_cnt;
    // ==================================

    always_ff @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        cmd_v_q   <= 1'b0;
        cmd_c_q   <= '0;
        data_valid<= 1'b0;
        data_nib  <= 4'h0;
        dv_cnt    <= 2'd0;
        // DELAY
        pending   <= 1'b0;
        delay_cnt <= '0;
      end else begin
        // 1Ŭ�� ����������
        cmd_v_q <= cmd_valid;
        if (cmd_valid) cmd_c_q <= cmd_code;

        // ===== ���� ���� FSM =====
        if (!pending) begin
          if (cmd_v_q) begin
            pending   <= 1'b1;
            delay_cnt <= (RESP_DELAY_CYCLES == 0) ? 32'd0 : RESP_DELAY_CYCLES - 1;
          end
        end else begin
          if (delay_cnt != 0) begin
            delay_cnt <= delay_cnt - 1'b1;
          end else begin
            // ���� ���� �� ���� ��� ����
            data_nib   <= do_cmd(cmd_c_q);
            data_valid <= 1'b1;
            dv_cnt     <= 2'd1;      // ����+���� Ŭ�� ����
            pending    <= 1'b0;
          end
        end

        // data_valid ����(����)
        if (dv_cnt != 2'd0) begin
          dv_cnt     <= dv_cnt - 1'b1;
          data_valid <= 1'b1;
        end else if (!pending) begin
          data_valid <= 1'b0;
        end
      end
    end

    assign otp_ack  = 1'b0;
    assign otp_dout = 4'h0;

  end else begin : g_pmod
  // ---------------- PMOD (USE_PMOD=1) ---------------
    // ��ȣ ����ȭ
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

    // ������/��� ��ġ
    logic        in_frame;
    logic [3:0]  sclk_cnt;
    logic [1:0]  cmd_code_q;

    // ===== DELAY PATCH (PMOD) =====
    typedef enum logic [1:0] {IDLE, PENDING, RESPOND} pstate_e;
    pstate_e     pstate;
    logic [31:0] delay_cnt;
    // ACK stretch ī����(���� �˳���)
    logic [7:0]  ack_cnt;
    // ===============================

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        in_frame   <= 1'b0;
        sclk_cnt   <= 4'd0;
        cmd_code_q <= 2'b00;
        otp_dout   <= 4'h0;
        otp_ack    <= 1'b0;
        // DELAY
        pstate     <= IDLE;
        delay_cnt  <= '0;
        ack_cnt    <= '0;
      end else begin
        // ������ ����(���� ����� ����)
        if (!in_frame && (req_rise || (req_high && sclk_rise))) begin
          in_frame <= 1'b1;
          sclk_cnt <= 4'd0;
        end
        // sclk ó��
        if (in_frame && sclk_rise) begin
          sclk_cnt <= sclk_cnt + 1'b1;
        end
        // ������ ����
        if (in_frame && req_fall) begin
          in_frame <= 1'b0;
          sclk_cnt <= 4'd0;
        end

        // ACK stretch: ī���Ͱ� ���������� ����
        otp_ack <= (ack_cnt != 0);
        if (ack_cnt != 0) begin
          ack_cnt <= ack_cnt - 1'b1;
        end

        // ===== ���� ���� ���¸ӽ� =====
        unique case (pstate)
          IDLE: begin
            // ù sclk ��¿������� CMD ���� (����: sclk_cnt==10 ����)
            if (in_frame && sclk_rise && (sclk_cnt == 4'd10)) begin
              cmd_code_q <= otp_cmd;
              // ���� ����
              pstate     <= (RESP_DELAY_CYCLES == 0) ? RESPOND : PENDING;
              delay_cnt  <= (RESP_DELAY_CYCLES == 0) ? 32'd0    : RESP_DELAY_CYCLES - 1;
            end
          end

          PENDING: begin
            if (delay_cnt != 0) begin
              delay_cnt <= delay_cnt - 1'b1;
            end else begin
              // ���� ���� �� ���� ����
              otp_dout <= do_cmd(cmd_code_q);
              otp_ack  <= 1'b1;
              // ACK ���� �� ����
              ack_cnt  <= (ACK_STRETCH_CYC == 0) ? 8'd1 : ACK_STRETCH_CYC[7:0];
              pstate   <= RESPOND;
            end
          end

          RESPOND: begin
            // ACK ���� �� IDLE ����
            if (ack_cnt == 0) begin
              pstate <= IDLE;
            end
          end
        endcase
      end
    end

    // ������ ��� �̻��
    assign data_valid = 1'b0;
    assign data_nib   = 4'h0;
  end endgenerate

  // ========================================================================
  // �� Read-only PK access window (8��32bit = 256bit)
  //   paddr[4:2] selects word index 0..7 (byte address ���� 0x00~0x1C)
  // ========================================================================
  wire [2:0] word_sel = paddr[4:2];
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
    if (cmd_valid)  $display("%t DEV CMD=%b", $time, cmd_code);
    if (data_valid) $display("%t DEV DATA_NIB=%h", $time, data_nib);
  end
`endif

endmodule
