// ============================================================================
// otp_client_apb.sv  (APB SFR + 4bit link HOST)  [Direct/Loopback/PMOD 공용]
//   - CMDW=2 : 00=SOFT(=1), 01=LCS(=2), 10=PKLS(LSB), 11=RESV
//   - sticky-DONE + latched DATA (DATA는 래치 읽기)
//   - APB write zero-wait ACK
//   - CMD 트리거: 실제 APB access 유효 싸이클(acc=psel&penable)에서 CMD write 상승에지 검출
//   - 디버그 SFR: 0x00A0~0x00AC, 0x00B0~0x00BC, 0x00B4=버전("OT8d"=0x4F543864)
//   - USE_PMOD=0: 보드 내 loopback(lb_*), USE_PMOD=1: 외부 PMOD(otp_*)
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

  // 버전 ASCII ('O','T', major, minor) - 기본 "OT8d" = 0x4F543864
  parameter byte OTP_VER_MAJOR_ASCII = "8",
  parameter byte OTP_VER_MINOR_ASCII = "d"
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

  // ------------- PMOD link (HOST↔DEVICE) -------------
  output logic           otp_sclk,     // host clock out (div2 when USE_PMOD=1)
  output logic           otp_req,      // host request
  input  logic           otp_ack,      // device data valid
  input  logic  [3:0]    otp_din,      // device → host data nibble

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
  localparam logic [AW-1:0] ADDR_DBG_VER    = 16'h00B4; // ★ version "OT8d"
  localparam logic [AW-1:0] ADDR_DBG_HS0    = 16'h00B8;
  localparam logic [AW-1:0] ADDR_DBG_HS1    = 16'h00BC;

  // 버전 상수 조립
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

  // ---- 링크 선택 (PMOD vs loopback)
  wire        data_valid_sel = (USE_PMOD) ? otp_ack      : lb_data_valid;
  wire [3:0]  data_sel       = (USE_PMOD) ? otp_din      : lb_data_nib;

  // ---- PMOD sclk (pclk/2)
  logic sclk_div;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) sclk_div <= 1'b0;
    else         sclk_div <= ~sclk_div;
  end
  always_comb begin
    otp_sclk = (USE_PMOD) ? sclk_div : 1'b0;
  end

  // ---- CMD write 트리거: 실제 access 유효 싸이클에서 상승 에지 검출
  wire          acc_cmd   = (psel & penable & pwrite & (a == ADDR_OTP_CMD));
  logic         acc_cmd_q;
  wire          cmd_fire  = acc_cmd & ~acc_cmd_q;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) acc_cmd_q <= 1'b0;
    else         acc_cmd_q <= acc_cmd;
  end

  // ---- CMD 레지스터 (cmd_fire 에서만 갱신)
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) cmd_reg <= '0;
    else if (cmd_fire)    cmd_reg <= pwdata[CMDW-1:0];
  end

  // 이번 싸이클 전송할 CMD (cmd_fire 시 pwdata, 그 외엔 cmd_reg)
  wire [CMDW-1:0] cmd_new      = pwdata[CMDW-1:0];
  wire [CMDW-1:0] cmd_to_issue = cmd_fire ? cmd_new : cmd_reg;

  // ---- next-state
  always_comb begin
    nx = st;
    unique0 case (st)
      H_IDLE : if (cmd_fire)      nx = H_REQ;    // APB-access 에지로만 시작
      H_REQ  :                     nx = H_WAIT;
      H_WAIT : if (data_valid_sel) nx = H_LATCH;
      H_LATCH:                     nx = H_IDLE;
    endcase
  end

  // ---- DEV/HS 디버그용 보조 레지스터
  logic [CMDW-1:0] last_cmd_code;      // 마지막으로 디바이스에 보낸 CMD 코드
  logic [3:0]      last_data_nib;      // 마지막으로 수신해 래치된 데이터 니블

  // ---- state/data regs
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      st <= H_IDLE;
      busy <= 1'b0; done_pulse<=1'b0; done_sticky<=1'b0;
      data_nib<=4'h0; data_nib_latched<=4'h0; cnt<=8'h00;
      otp_req<=1'b0; lb_cmd_valid<=1'b0; lb_cmd_code<='0;
      last_cmd_code<='0; last_data_nib<=4'h0;
    end else begin
      st <= nx;
      done_pulse   <= 1'b0;
      lb_cmd_valid <= 1'b0;

      unique0 case (st)
        H_IDLE: begin
          busy    <= 1'b0;
          otp_req <= 1'b0;
        end
        H_REQ: begin
          busy        <= 1'b1;
          done_sticky <= 1'b0;                // 새 CMD: sticky 클리어
          last_cmd_code <= cmd_to_issue;
          if (USE_PMOD) begin
            otp_req <= 1'b1;
          end else begin
            lb_cmd_code  <= cmd_to_issue;     // loopback으로 1클럭 펄스
            lb_cmd_valid <= 1'b1;
          end
        end
        H_WAIT: begin
          if (USE_PMOD) otp_req <= 1'b1;      // 요청 유지
        end
        H_LATCH: begin
          data_nib         <= data_sel;
          data_nib_latched <= data_sel;       // DATA read-back은 래치값
          last_data_nib    <= data_sel;
          cnt              <= cnt + 1;
          busy             <= 1'b0;
          done_pulse       <= 1'b1;
          done_sticky      <= 1'b1;           // sticky ON
          otp_req          <= 1'b0;
        end
      endcase
    end
  end

  // ---- APB read-back (쓰기에도 zero-wait ACK)
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      pready <= 1'b0;
      prdata <= 32'h0;
    end else begin
      pready <= 1'b0;
      if (rd) begin
        pready <= 1'b1;
        unique0 case (a)
          // 정상 SFR
          ADDR_OTP_STATUS: prdata <= {30'h0, done_sticky, busy};
          ADDR_OTP_DATA  : prdata <= {28'h0, data_nib_latched};
          ADDR_OTP_CNT   : prdata <= {24'h0, cnt};

          // 디버그 SFR
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
            // [.. raw/latched 동시 노출]
            prdata <= {24'h0, 4'h0, data_nib, data_nib_latched};
          end
          ADDR_DBG_CNT:  prdata <= {24'h0, cnt};

          ADDR_DBG_DEV0: begin
            // [17:16]=last_cmd_code, [3:0]=last_data_nib
            prdata <= {14'h0, last_cmd_code, 12'h0, last_data_nib};
          end
          ADDR_DBG_VER : prdata <= DBG_VER_VALUE;    // ★ "OT8d"=0x4F543864
          ADDR_DBG_HS0 : begin
            // 간단 호스트 스냅샷: [21:20]=cmd_to_issue, [9:8]=st, [1]=done_sticky, [0]=busy
            prdata <= {10'h0, cmd_to_issue, 10'h0, st, 6'h0, done_sticky, busy};
          end
          ADDR_DBG_HS1 : begin
            // 여유 필드 (확장용)
            prdata <= 32'h0;
          end

          default        : prdata <= 32'h0;
        endcase
      end else if (wr) begin
        pready <= 1'b1;  // ★ write-zero-wait ACK
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge pclk) begin
    if (cmd_fire) $display("%t HOST: CMD(access)=%b", $time, cmd_new);
  end
`endif

endmodule
