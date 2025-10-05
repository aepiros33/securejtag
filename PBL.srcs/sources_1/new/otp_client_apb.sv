// ============================================================================
// otp_client_apb.sv
// (FINAL v8a) READ-after-LATCH 정확화 + baseline READ 허용
//   - DATA/CNT READ는 기본적으로 H_LATCH 다음 클럭에만 ACK (최신값 보장)
//   - 단, ever_latched==0(부팅 후 첫 READ)일 때는 즉시 ACK하여 0값 반환 → 타임아웃 방지
//   - EXT trigger/code 정렬, Debug SFR 유지
//   - Map: 0x0090 CMD(wo), 0x0094 STATUS(ro), 0x0098 DATA(ro), 0x009C CNT(ro)
//           0x00A0~0x00BC: 디버그
// ============================================================================

`timescale 1ns/1ps
module otp_client_apb #(
  parameter int AW           = 16,
  parameter int CMDW         = 2,
  parameter bit USE_PMOD     = 1'b0,
  parameter bit USE_EXT_TRIG = 1'b1
)(
  input  logic           pclk,
  input  logic           presetn,

  // -------- APB slave --------
  input  logic           psel,
  input  logic           penable,
  input  logic           pwrite,
  input  logic [31:0]    paddr,
  input  logic [31:0]    pwdata,
  output logic [31:0]    prdata,
  output logic           pready,

  // -------- PMOD link (HOST→DEVICE) --------
  output logic           otp_sclk,
  output logic           otp_req,
  input  logic           otp_ack,
  input  logic  [3:0]    otp_din,

  // -------- Loopback (single-board) --------
  output logic               lb_cmd_valid,
  output logic [CMDW-1:0]    lb_cmd_code,
  input  logic               lb_data_valid,
  input  logic  [3:0]        lb_data_nib,

  // -------- External robust trigger --------
  input  logic               ext_cmd_fire,   // 1clk pulse (정렬된)
  input  logic [CMDW-1:0]    ext_cmd_code,

  // -------- Device-side debug taps (from server) --------
  input  logic               dev_cmd_seen,
  input  logic [CMDW-1:0]    dev_cmd_code_q,
  input  logic               dev_data_valid,
  input logic [3:0]          dev_data_nib,
  input  logic [1:0]         dev_dv_cnt
);

  // ---------- APB map ----------
  localparam logic [AW-1:0] ADDR_OTP_CMD    = 16'h0090;
  localparam logic [AW-1:0] ADDR_OTP_STATUS = 16'h0094;
  localparam logic [AW-1:0] ADDR_OTP_DATA   = 16'h0098; // DATA(latched)
  localparam logic [AW-1:0] ADDR_OTP_CNT    = 16'h009C; // CNT

  localparam logic [AW-1:0] ADDR_DBG_CMD    = 16'h00A0;
  localparam logic [AW-1:0] ADDR_DBG_STAT   = 16'h00A4;
  localparam logic [AW-1:0] ADDR_DBG_DATA   = 16'h00A8;
  localparam logic [AW-1:0] ADDR_DBG_CNT    = 16'h00AC;
  localparam logic [AW-1:0] ADDR_DBG_DEV0   = 16'h00B0;
  localparam logic [AW-1:0] ADDR_DBG_DEV1   = 16'h00B4;
  localparam logic [AW-1:0] ADDR_DBG_HOST0  = 16'h00B8;
  localparam logic [AW-1:0] ADDR_DBG_HOST1  = 16'h00BC;

  // ---------------- APB access ----------------
  wire [AW-1:0] a   = paddr[AW-1:0];
  wire          acc = psel & penable;
  wire          rd  = acc & ~pwrite;
  wire          wr  = acc &  pwrite;

  // record last addr for debug
  logic [AW-1:0] last_rd_addr, last_wr_addr;
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin last_rd_addr <= '0; last_wr_addr <= '0; end
    else begin if (rd) last_rd_addr <= a; if (wr) last_wr_addr <= a; end
  end

  // ---------------- Host FSM ------------------
  typedef enum logic [1:0] {H_IDLE,H_REQ,H_WAIT,H_LATCH} hst_e;
  hst_e st, nx;

  logic [CMDW-1:0] cmd_reg;
  logic            busy, done_pulse, done_sticky;
  logic [3:0]      data_nib, data_nib_latched;
  logic [7:0]      cnt;

  // READ-after-LATCH 보장용 shadow + ready 파이프
  logic [3:0]      data_shadow;
  logic [7:0]      cnt_shadow;
  logic            rd_ready_stage;
  logic            rd_ready;
  logic            ever_latched;     // ★ 추가: 첫 LATCH 이전 baseline READ 허용

  // ---- PMOD sclk (pclk/2)
  logic sclk_div;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) sclk_div <= 1'b0; else sclk_div <= ~sclk_div;
  end
  always_comb otp_sclk = (USE_PMOD) ? sclk_div : 1'b0;

  // ---- 링크 선택 (PMOD vs loopback)
  wire        data_valid_sel = (USE_PMOD) ? otp_ack      : lb_data_valid;
  wire [3:0]  data_sel       = (USE_PMOD) ? otp_din      : lb_data_nib;

  // ======================================================================
  // CMD 트리거: EXT 우선(정렬됨), APB(setup-edge) 보조
  // ======================================================================
  logic psel_q;
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) psel_q <= 1'b0; else psel_q <= psel;
  end
  wire apb_setup      =  psel & ~psel_q;
  wire apb_cmd_fire_w =  apb_setup & pwrite & (a == ADDR_OTP_CMD);
  logic apb_cmd_fire_q;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) apb_cmd_fire_q <= 1'b0; else apb_cmd_fire_q <= apb_cmd_fire_w;
  end
  wire apb_cmd_fire   = apb_cmd_fire_w & ~apb_cmd_fire_q;

  wire          cmd_fire_i = (USE_EXT_TRIG ? ext_cmd_fire : apb_cmd_fire);
  wire [CMDW-1:0]cmd_new_i = (USE_EXT_TRIG ? ext_cmd_code : pwdata[CMDW-1:0]);

  // ---- CMD 레지스터 + issue 선택
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn)          cmd_reg <= '0;
    else if(cmd_fire_i)   cmd_reg <= cmd_new_i;
  end
  wire [CMDW-1:0] cmd_to_issue = cmd_fire_i ? cmd_new_i : cmd_reg;

  // ---- FSM next
  always_comb begin
    nx = st;
    unique case(st)
      H_IDLE : if (cmd_fire_i)     nx = H_REQ;
      H_REQ  :                     nx = H_WAIT;
      H_WAIT : if (data_valid_sel) nx = H_LATCH;
      H_LATCH:                     nx = H_IDLE;
    endcase
  end

  // ---- FSM regs
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin
      st<=H_IDLE; busy<=1'b0; done_pulse<=1'b0; done_sticky<=1'b0;
      data_nib<=4'h0; data_nib_latched<=4'h0;
      data_shadow<=4'h0; cnt<=8'h00; cnt_shadow<=8'h00;
      rd_ready_stage<=1'b0; rd_ready<=1'b0; ever_latched<=1'b0;  // ★
      otp_req<=1'b0; lb_cmd_valid<=1'b0; lb_cmd_code<='0;
    end else begin
      st<=nx; done_pulse<=1'b0; lb_cmd_valid<=1'b0;

      // rd_ready 파이프
      rd_ready <= rd_ready_stage;     // H_LATCH 다음 클럭부터 1

      unique case(st)
        H_IDLE: begin
          busy    <= 1'b0;
          otp_req <= 1'b0;
        end

        H_REQ: begin
          busy           <= 1'b1;
          done_sticky    <= 1'b0;     // 새 CMD 시작
          rd_ready_stage <= 1'b0;     // 다음 READ 대기는 다시 잠금
          if (USE_PMOD) otp_req <= 1'b1;
          else begin
            lb_cmd_code  <= cmd_to_issue;
            lb_cmd_valid <= 1'b1;     // 1클럭 펄스
          end
        end

        H_WAIT: begin
          if (USE_PMOD) otp_req <= 1'b1;
        end

        H_LATCH: begin
          data_nib         <= data_sel;
          data_nib_latched <= data_sel;
          cnt              <= cnt + 1;

          // READ-back shadow (증분 후 값)
          data_shadow      <= data_sel;
          cnt_shadow       <= cnt + 1;

          busy             <= 1'b0;
          done_pulse       <= 1'b1;
          done_sticky      <= 1'b1;

          ever_latched     <= 1'b1;   // ★ baseline 종료
          rd_ready_stage   <= 1'b1;   // 다음 클럭부터 ACK OK

          otp_req          <= 1'b0;
        end
      endcase
    end
  end

  // ======================================================================
  // APB READ / WRITE ACK
  // ======================================================================
  wire sel_data    = (a == ADDR_OTP_DATA);
  wire sel_cnt     = (a == ADDR_OTP_CNT);
  wire rd_data_req = rd && sel_data;
  wire rd_cnt_req  = rd && sel_cnt;

  // ★ baseline(ever_latched==0)에서는 즉시 ACK 허용
  wire rd_gate_dc  = (rd_data_req || rd_cnt_req);
  wire rd_can_ack  = rd && ( rd_gate_dc ? (rd_ready || !ever_latched) : 1'b1 );

  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin pready<=1'b0; prdata<=32'h0; end
    else begin
      pready<=1'b0;

      if (rd_can_ack) begin
        pready <= 1'b1;
        unique case(a)
          ADDR_OTP_STATUS: prdata <= {30'h0, done_sticky, busy};
          ADDR_OTP_DATA  : prdata <= {28'h0, data_shadow}; // baseline이면 0
          ADDR_OTP_CNT   : prdata <= {24'h0, cnt_shadow};  // baseline이면 0

          // ---- Host debug
          ADDR_DBG_CMD   : prdata <= {16'h0,
                                      cmd_fire_i, apb_cmd_fire, ext_cmd_fire, 1'b0, 1'b0,
                                      st, busy, done_sticky,
                                      3'b000, cmd_reg[1:0], cmd_to_issue[1:0]};
          ADDR_DBG_STAT  : prdata <= {27'h0, st, busy, done_pulse, done_sticky};
          ADDR_DBG_DATA  : prdata <= {24'h0, data_nib, data_nib_latched};
          ADDR_DBG_CNT   : prdata <= {24'h0, cnt};

          // ---- Device debug
          ADDR_DBG_DEV0  : prdata <= {20'h0,
                                      dev_cmd_seen, 1'b0,
                                      dev_cmd_code_q,
                                      dev_data_valid,
                                      2'b0, dev_dv_cnt,
                                      dev_data_nib};
          ADDR_DBG_DEV1  : prdata <= 32'h0000_0000;

          // ---- Host trigger snapshot
          ADDR_DBG_HOST0 : prdata <= {20'h0,
                                      ext_cmd_code,
                                      apb_cmd_fire,
                                      ext_cmd_fire,
                                      2'b0,
                                      cmd_new_i,
                                      cmd_reg,
                                      cmd_to_issue};
          ADDR_DBG_HOST1 : prdata <= {20'h0,
                                      psel, penable, pwrite, (a==ADDR_OTP_CMD),
                                      last_rd_addr[7:0], last_wr_addr[7:0]};

          default        : prdata <= 32'h0;
        endcase

      end else if (wr) begin
        pready <= 1'b1;  // WRITE는 zero-wait
      end
    end
  end

endmodule
