// ============================================================================
// auth_fsm_pk4.sv  --  OTP 4bit ��� ���� FSM (���� ���� ����: �ټ��� ����)
//   - START ������: SOFT(00) 1ȸ �� (�ɼ�) LCS(01) 1ȸ �� PKLS(10) 1ȸ
//   - ��: PK_IN[3:0] vs PKLS �� pk_match/pass/why_denied
//   - otp_client_apb �� �ܺ� ��� ���� ��Ʈ(ext_*)�� ���� �ڵ����ũ
//   - busy/done/pk_match/pass/why_denied �� regfile/status�� �״�� ����
// ============================================================================
`timescale 1ns/1ps
module auth_fsm_pk4 #(
  parameter int PKW       = 256,
  parameter bit READ_LCS  = 1'b1   // 1�̸� LCS�� 1ȸ �о� ����
)(
  input  logic              clk,
  input  logic              rst_n,

  // Ʈ����/Ŭ����
  input  logic              start,
  input  logic              clear,

  // PK �Է� (LSB 4��Ʈ�� ���)
  input  logic [PKW-1:0]    pk_input,
  input  logic [PKW-1:0]    pk_allow, // ȣȯ��(�̻��)

  // otp_client_apb �ܺ� ��� ���� �������̽�
  output logic              ext_cmd_fire,
  output logic [1:0]        ext_cmd_code,   // 00=SOFT, 01=LCS, 10=PKLS
  input  logic              ext_busy,
  input  logic              ext_done,       // 1Ŭ�� �޽�
  input  logic [3:0]        ext_data_nib,   // DONE ������ �Ϻ�

  // ����/���
  output logic              busy,
  output logic              done,           // 1Ŭ�� �޽�
  output logic              pk_match,
  output logic              pass,

  // OTP���� ���� �� ����(��å/����׿�)
  output logic              soft_bit,
  output logic [2:0]        lcs_bits,

  // WHY �ڵ�(��: 0x08 = PK_MISMATCH)
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

  // ��ġ
  logic [2:0] lcs_q;
  logic [3:0] pkls_q;

  // �⺻/����
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      st <= S_IDLE;
      busy <= 1'b0;
      done <= 1'b0;
      pk_match <= 1'b0;
      pass <= 1'b0;
      why_denied <= 8'h00;
      soft_bit <= 1'b1; // ������(���) �⺻
      lcs_q <= 3'b000;
      pkls_q <= 4'h0;
      ext_cmd_fire <= 1'b0;
      ext_cmd_code <= 2'b00;
    end else begin
      // �⺻ Ŭ����
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

          // SOFT �� ���� �б�
          S_SOFT_ISS: begin
            ext_cmd_code <= 2'b00;
            ext_cmd_fire <= 1'b1;   // 1Ŭ�� �޽�
          end
          S_SOFT_WAIT: begin
            if (ext_done) begin
              soft_bit <= ext_data_nib[0];
            end
          end

          // (�ɼ�) LCS �� �� �б�
          S_LCS_ISS: begin
            ext_cmd_code <= 2'b01;
            ext_cmd_fire <= 1'b1;
          end
          S_LCS_WAIT: begin
            if (ext_done) begin
              lcs_q <= ext_data_nib[2:0];
            end
          end

          // PKLS �� �� �б�
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
            done <= 1'b1;   // 1Ŭ�� �޽�
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
