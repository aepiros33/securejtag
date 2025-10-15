// ============================================================================
// otp_client_apb.sv  (APB SFR + 4bit link HOST)  [Direct/Loopback/PMOD ����]
//   - CMDW=2 : 11=SOFT(=3), 01=LCS(=2), 10=PKLS(LSB), 00=RESV
//   - sticky-DONE + latched DATA (DATA�� ��ġ �б�)
//   - APB write zero-wait ACK
//   - CMD Ʈ����: ���� APB access ��ȿ ����Ŭ(acc=psel&penable)���� CMD write ��¿��� ����
//   - ����� SFR: 0x00A0~0x00AC, 0x00B0~0x00BC, 0x00B4=����("OT8d"=0x4F543864)
//   - USE_PMOD=0: ���� �� loopback(lb_*), USE_PMOD=1: �ܺ� PMOD(otp_*)
//   - APB map:
//       0x0090: OTP_CMD    (WO)  [CMDW-1:0]
//       0x0094: OTP_STATUS (RO)  [1]=DONE(sticky), [0]=BUSY
//       0x0098: OTP_DATA   (RO)  [3:0] latched nibble
//       0x009C: OTP_CNT    (RO)  [7:0] completed count
//       0x00A0: DBG_CMD    (RO)
//       0x00A4: DBG_STAT   (RO)
//       0x00A8: DBG_DATA   (RO)
//       0x00AC: DBG_CNT    (RO)
//       0x00B0: DBG_DEV0   (RO)  [17:16]=last_cmd_code, [3:0]=last_data_nib
//       0x00B4: DBG_VER    (RO)  "OT8d"=0x4F543864
//       0x00B8: DBG_HS0    (RO)
//       0x00BC: DBG_HS1    (RO)
// ============================================================================

`timescale 1ns/1ps
module otp_client_apb #(
  parameter int AW       = 16,
  parameter int CMDW     = 2,
  parameter bit USE_PMOD = 1'b0,
  parameter bit AUTO_READ_SOFT = 1'b0, // �� �߰�: ���� �� �ڵ� READ_SOFT
  parameter int AUTO_DELAY = 5000, // pclk=100MHz�� ?50us ����

  // ���� ASCII ('O','T', major, minor) - �⺻ "OT8d" = 0x4F543864
  parameter byte OTP_VER_MAJOR_ASCII = "9",
  parameter byte OTP_VER_MINOR_ASCII = "a"
)(
  input  logic           pclk,
  input  logic           presetn,

  // ---------------- APB SLAVE ----------------
  input  logic           psel,
  input  logic           penable,
  input  logic           pwrite,
  input  logic [31:0]    paddr,
  input  logic [31:0]    pwdata,
  output logic [31:0]    prdata,
  output logic           pready,

  // ------------- PMOD link (HOST��DEVICE) -------------
  output logic           otp_sclk,   // Host �� Dev
  output logic           otp_req,    // Host �� Dev
  output logic [1:0]     otp_cmd,    // Host �� Dev  �� �߰�
  input  logic           otp_ack,    // Dev  �� Host
  input  logic  [3:0]    otp_din,     // Dev  �� Host
  output logic           otp_read_soft_done, // 1-cycle pulse on READ_SOFT
  output logic           otp_read_soft_val,   // soft bit value (LSB)
  // ------------- Loopback (single-board) -------------
  output logic           lb_cmd_valid,
  output logic [CMDW-1:0]lb_cmd_code,
  input  logic           lb_data_valid,
  input  logic  [3:0]    lb_data_nib
);

  // ---------- APB map ----------
  localparam logic [AW-1:0] ADDR_OTP_CMD    = 16'h0090; // WO
  localparam logic [AW-1:0] ADDR_OTP_STATUS = 16'h0094; // RO [1:0] = {done_sticky, busy}
  localparam logic [AW-1:0] ADDR_OTP_DATA   = 16'h0098; // RO [3:0] latched nibble
  localparam logic [AW-1:0] ADDR_OTP_CNT    = 16'h009C; // RO [7:0] nibble count

  localparam logic [AW-1:0] ADDR_DBG_CMD    = 16'h00A0;
  localparam logic [AW-1:0] ADDR_DBG_STAT   = 16'h00A4;
  localparam logic [AW-1:0] ADDR_DBG_DATA   = 16'h00A8;
  localparam logic [AW-1:0] ADDR_DBG_CNT    = 16'h00AC;
  localparam logic [AW-1:0] ADDR_DBG_DEV0   = 16'h00B0;
  localparam logic [AW-1:0] ADDR_DBG_VER    = 16'h00B4; // �� version "OT8d"
  localparam logic [AW-1:0] ADDR_DBG_HS0    = 16'h00B8;
  localparam logic [AW-1:0] ADDR_DBG_HS1    = 16'h00BC;
  localparam logic [1:0] READ_SOFT = 2'b11;  // �� �ʼ� ����
  
  // ���� ��� ����
  localparam logic [31:0] DBG_VER_VALUE =
    {8'h4F/*'O'*/, 8'h54/*'T'*/, OTP_VER_MAJOR_ASCII, OTP_VER_MINOR_ASCII};

  // ---------------- APB access ----------------
  wire [AW-1:0] a   = paddr[AW-1:0];
  wire          acc = psel & penable;          // APB access phase
  wire          rd  = acc & ~pwrite;
  wire          wr  = acc &  pwrite;

  // ---------------- Host FSM ------------------
  typedef enum logic [1:0] {H_IDLE, H_REQ, H_WAIT, H_LATCH} hst_e;
  hst_e st, nx;

  logic [CMDW-1:0] cmd_reg;
  logic            busy, done_pulse, done_sticky;
  logic [3:0]      data_nib, data_nib_latched;
  logic [7:0]      cnt;
  logic [1:0]      otp_cmd_q;
  logic            otp_read_soft_done_r; // pulse reg
  logic            auto_pending; // �� �߰�
  logic [$clog2(AUTO_DELAY):0] auto_cnt;
  logic issued_is_soft;  // �� �������� READ_SOFT������ ��ġ
  logic [CMDW-1:0] last_cmd_code;      // ���������� ����̽��� ���� CMD �ڵ�
  
  // PMOD �Է� ����ȭ/���� ����/������ ĸó
  logic [2:0] ack_sync;
  logic       ack_rise;
  logic [3:0] data_cap;
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      ack_sync <= 3'b000;
      data_cap <= 4'h0;
    end else begin
      ack_sync <= {ack_sync[1:0], otp_ack};
      if (ack_sync[2:1] == 2'b01) begin
        data_cap <= otp_din;  // ack ��¿������� ������ ����
      end
    end
  end
  assign ack_rise = (ack_sync[2:1] == 2'b01);

  // ---- ��ũ ���� (PMOD vs loopback)
  wire        data_valid_sel = (USE_PMOD) ? ack_rise : lb_data_valid;
  wire [3:0]  data_sel       = (USE_PMOD) ? data_cap : lb_data_nib;
  
  // (����) auto_pending���� ���� �������� �ʱ�
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin
      auto_cnt <= AUTO_DELAY;
    end else if (auto_pending && auto_cnt != 0) begin
      auto_cnt <= auto_cnt - 1'b1;
    end
  end



wire auto_fire = USE_PMOD && auto_pending && (auto_cnt == 0);

  // ---- PMOD sclk (pclk/2)
  logic sclk_div;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) sclk_div <= 1'b0;
    else         sclk_div <= ~sclk_div;
  end
  always_comb begin
    otp_sclk = (USE_PMOD) ? sclk_div : 1'b0;
    // cmd: USE_PMOD�� ���� ������ ������ cmd ������ (�ƴϸ� 0)
    otp_cmd  = (USE_PMOD) ? otp_cmd_q : 2'b00;
  end

  // ---- CMD write Ʈ����: ���� access ��ȿ ����Ŭ���� ��� ���� ����
  wire          acc_cmd   = (psel & penable & pwrite & (a == ADDR_OTP_CMD));
  logic         acc_cmd_q;
  wire          cmd_fire  = acc_cmd & ~acc_cmd_q;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) acc_cmd_q <= 1'b0;
    else         acc_cmd_q <= acc_cmd;
  end

  // ---- CMD �������� (cmd_fire ������ ����)
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) cmd_reg <= '0;      
    else if (cmd_fire)    cmd_reg <= pwdata[CMDW-1:0];
  end

  // �̹� ����Ŭ ������ CMD (cmd_fire �� pwdata, �� �ܿ� cmd_reg)
  wire [CMDW-1:0] cmd_new      = pwdata[CMDW-1:0];
  wire [CMDW-1:0] cmd_to_issue = cmd_fire ? cmd_new : cmd_reg;

  // �� H_REQ ���� ������ �̹� �������� cmd�� ������ �ɿ� ����
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      otp_cmd_q <= READ_SOFT;      
      issued_is_soft <= 1'b0;
      last_cmd_code   <= 2'b00;   // �� �ʱ�ȭ�� ���⼭��
    end else begin
      // �� IDLE��REQ ���� ������ '�̹��� ������ �� CMD'�� �� ���� Ȯ��
      if ((st==H_IDLE && nx==H_REQ)) begin
        logic [1:0] issued_cmd;
        if (cmd_fire)       issued_cmd = cmd_new;      // ���� CMD
        else if (auto_fire) issued_cmd = READ_SOFT;    // ����
        else                issued_cmd = cmd_reg;      // (����� �⺻��)
        
        otp_cmd_q      <= issued_cmd;                  // �� ������ ���� �ҽ�
        last_cmd_code  <= issued_cmd;                  // ����׿�
        issued_is_soft <= (issued_cmd == READ_SOFT);   // �� �̹� �������� SOFT������ ���
      end
    end
  end
  // ---- next-state
  always_comb begin
    nx = st;
    unique0 case (st)
      //H_IDLE : if (cmd_fire || (USE_PMOD && auto_pending)) nx = H_REQ; // �� �߰�
      H_IDLE : if (cmd_fire || auto_fire) nx = H_REQ;
      H_REQ  :                     nx = H_WAIT;
      H_WAIT : if (data_valid_sel) nx = H_LATCH;
      H_LATCH:                     nx = H_IDLE;
    endcase
  end

  // ---- DEV/HS ����׿� ���� ��������

  logic [3:0]      last_data_nib;      // ���������� ������ ��ġ�� ������ �Ϻ�

  // ---- state/data regs
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      st <= H_IDLE;
      busy <= 1'b0; done_pulse<=1'b0; done_sticky<=1'b0;
      data_nib<=4'h0; data_nib_latched<=4'h0; cnt<=8'h00;
      otp_req<=1'b0; lb_cmd_valid<=1'b0; lb_cmd_code<='0;
      last_data_nib<=4'h0;
      
      otp_read_soft_done_r <= 1'b0;
      otp_read_soft_val    <= 1'b0;
      
      auto_pending <= AUTO_READ_SOFT;   // �� ���� �� 1ȸ �ڵ� READ_SOFT arm
    end else begin
      st <= nx;
      otp_read_soft_done_r <= 1'b0;  // default deassert
      done_pulse   <= 1'b0;
      lb_cmd_valid <= 1'b0;

      unique0 case (st)
        H_IDLE: begin
          busy    <= 1'b0;
          otp_req <= 1'b0;
        end
        H_REQ: begin
          busy        <= 1'b1;
          done_sticky <= 1'b0;                // �� CMD: sticky Ŭ����

          if (USE_PMOD) begin
            otp_req <= 1'b1;            
            //if (!cmd_fire && auto_pending) last_cmd_code <= 2'b00; // �� �ڵ��� �� ǥ��            
          end else begin
            lb_cmd_code  <= last_cmd_code;   // �� IDLE��REQ���� Ȯ���� ���� �߻� CMD�� ���
            lb_cmd_valid <= 1'b1;
          end
        end
        H_WAIT: begin
          if (USE_PMOD) otp_req <= 1'b1;      // ��û ����
        end
        H_LATCH: begin
          data_nib         <= data_sel;
          data_nib_latched <= data_sel;       // DATA read-back�� ��ġ��
          last_data_nib    <= data_sel;
          cnt              <= cnt + 1;
          busy             <= 1'b0;
          done_pulse       <= 1'b1;
          done_sticky      <= 1'b1;           // sticky ON
          otp_req          <= 1'b0;
          if (auto_pending) auto_pending <= 1'b0; // �� �ڵ� 1ȸ��
          // ����:
          if (issued_is_soft) begin
            otp_read_soft_val    <= data_sel[0];
            otp_read_soft_done_r <= 1'b1;
          end
        end
      endcase
    end
  end

  assign otp_read_soft_done = otp_read_soft_done_r;
  // ---- APB read-back (���⿡�� zero-wait ACK)
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      pready <= 1'b0;
      prdata <= 32'h0;
    end else begin
      pready <= 1'b0;
      if (rd) begin
        pready <= 1'b1;
        unique0 case (a)
          // ���� SFR
          ADDR_OTP_STATUS: prdata <= {30'h0, done_sticky, busy};
          ADDR_OTP_DATA  : prdata <= {28'h0, data_nib_latched};
          ADDR_OTP_CNT   : prdata <= {24'h0, cnt};

          // ����� SFR
          ADDR_DBG_CMD: begin
            // [.. st(2), busy(1), done_sticky(1), acc_cmd(1), cmd_fire(1), cmd_to_issue(2), cmd_reg(2) ..]
            prdata <= {24'h0,
                       st, busy, done_sticky,
                       acc_cmd, cmd_fire,
                       cmd_to_issue, cmd_reg};
          end
          ADDR_DBG_STAT: begin
            // st(2), busy, done_pulse, done_sticky
            prdata <= {27'h0, st, busy, done_pulse, done_sticky};
          end
          ADDR_DBG_DATA: begin
            // [.. raw/latched ���� ����]
            prdata <= {24'h0, 4'h0, data_nib, data_nib_latched};
          end
          ADDR_DBG_CNT:  prdata <= {24'h0, cnt};

          ADDR_DBG_DEV0: begin
            // [17:16]=last_cmd_code, [3:0]=last_data_nib
            prdata <= {14'h0, last_cmd_code, 12'h0, last_data_nib};
          end
          ADDR_DBG_VER : prdata <= DBG_VER_VALUE;    // �� "OT8d"=0x4F543864
          ADDR_DBG_HS0 : begin
            // ���� ȣ��Ʈ ������: [21:20]=cmd_to_issue, [9:8]=st, [1]=done_sticky, [0]=busy
            prdata <= {10'h0, last_cmd_code, 10'h0, st, 6'h0, done_sticky, busy};
          end
          ADDR_DBG_HS1 : begin
            // ���� �ʵ� (Ȯ���)
            prdata <= 32'h0;
          end

          default        : prdata <= 32'h0;
        endcase
      end else if (wr) begin
        pready <= 1'b1;  // �� write-zero-wait ACK
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge pclk) begin
    if (cmd_fire) $display("%t HOST: CMD(access)=%b", $time, cmd_new);
  end
`endif

endmodule
