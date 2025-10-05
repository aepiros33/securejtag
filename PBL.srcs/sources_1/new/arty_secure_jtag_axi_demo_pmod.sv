// ============================================================================
// arty_secure_jtag_axi_demo_pmod.sv
//   ▶ PMOD wrapper TOP (두 보드 모드; PMOD 핀 제약 필요)
//   ▶ 2보드로 확장할 때 이 모듈을 Top으로 사용하세요.
//     - 호스트(보드1): 이 래퍼를 Top으로, PMOD 핀 XDC 매핑
//     - 디바이스(보드2): 별도의 server 전용 Top을 올리는 구성이 일반적
//       (원하면 별도 server-top도 만들어 줄 수 있음)
// ============================================================================

`timescale 1ns/1ps
module arty_secure_jtag_axi_demo_pmod (
  input  logic        CLK100MHZ,
  input  logic [3:0]  btn,

  // PMOD HOST pins
  output logic        otp_sclk,
  output logic        otp_req,
  input  logic        otp_ack,
  input  logic [3:0]  otp_din,

  // LEDs
  output logic [3:0]  led,
  output logic        led0_r, led0_g,
  output logic        led1_r, led1_b
);
  // 이 래퍼는 PMOD를 노출하는 버전입니다.
  // 내부 시스템은 core와 거의 동일하지만, OTP host는 USE_PMOD=1로 동작시키고
  // loopback device는 두지 않습니다(외부 보드2가 응답).

  // ---------------- Clock / Reset ----------------
  wire pclk    = CLK100MHZ;
  wire presetn = ~btn[0];

  // ---------------- JTAG-to-AXI ------------------
  wire [31:0] m_axi_awaddr, m_axi_wdata, m_axi_araddr, m_axi_rdata;
  wire        m_axi_awvalid, m_axi_awready;
  wire  [3:0] m_axi_wstrb;
  wire        m_axi_wvalid,  m_axi_wready;
  wire  [1:0] m_axi_bresp;
  wire        m_axi_bvalid,  m_axi_bready;
  wire        m_axi_arvalid, m_axi_arready;
  wire  [1:0] m_axi_rresp;
  wire        m_axi_rvalid,  m_axi_rready;

  jtag_axi_0 jtag_axi_i (
    .aclk          (pclk),
    .aresetn       (presetn),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awprot  (),
    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_wdata   (m_axi_wdata),
    .m_axi_wstrb   (m_axi_wstrb),
    .m_axi_wvalid  (m_axi_wvalid),
    .m_axi_wready  (m_axi_wready),
    .m_axi_bresp   (m_axi_bresp),
    .m_axi_bvalid  (m_axi_bvalid),
    .m_axi_bready  (m_axi_bready),
    .m_axi_araddr  (m_axi_araddr),
    .m_axi_arprot  (),
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready)
  );

  // ------------- AXI-Lite -> APB ----------------
  logic        psel, penable, pwrite, pready;
  logic [31:0] paddr, pwdata, prdata;

  axi_lite2apb_bridge #(.AW(16), .AXI_BASE(32'h4000_0000)) u_ax2apb (
    .aclk          (pclk),
    .aresetn       (presetn),
    .s_axi_awaddr  (m_axi_awaddr),
    .s_axi_awvalid (m_axi_awvalid),
    .s_axi_awready (m_axi_awready),
    .s_axi_wdata   (m_axi_wdata),
    .s_axi_wstrb   (m_axi_wstrb),
    .s_axi_wvalid  (m_axi_wvalid),
    .s_axi_wready  (m_axi_wready),
    .s_axi_bresp   (m_axi_bresp),
    .s_axi_bvalid  (m_axi_bvalid),
    .s_axi_bready  (m_axi_bready),
    .s_axi_araddr  (m_axi_araddr),
    .s_axi_arvalid (m_axi_arvalid),
    .s_axi_arready (m_axi_arready),
    .s_axi_rdata   (m_axi_rdata),
    .s_axi_rresp   (m_axi_rresp),
    .s_axi_rvalid  (m_axi_rvalid),
    .s_axi_rready  (m_axi_rready),
    .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready)
  );

  // ------------- APB -> simple bus ---------------
  logic         bus_cs, bus_we;
  logic [15:0]  bus_addr;
  logic [31:0]  bus_wdata, bus_rdata;
  logic         bus_rvalid;
  logic         pslverr_unused;

  apb_reg_bridge #(.AW(16)) u_apb_bridge (
    .pclk(pclk), .presetn(presetn),
    .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr_unused),
    .bus_cs(bus_cs), .bus_we(bus_we),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata),
    .bus_rdata(bus_rdata), .bus_rvalid(bus_rvalid)
  );

  // ---------------- Filter -----------------------
  logic         rb_cs, rb_we;
  logic [15:0]  rb_addr;
  logic [31:0]  rb_wdata, rb_rdata;
  logic         rb_rvalid;

  // session/policy
  logic         soft_lock, dbgen;
  logic [2:0]   lcs;
  logic [5:0]   tzpc;
  logic [3:0]   domain, access_lv;
  logic [7:0]   why_denied;
  logic         bypass_en;

  regbus_filter_prepost #(.AW(16)) u_filter (
    .clk(pclk), .rst_n(presetn),
    .cs_in(bus_cs), .we_in(bus_we), .addr_in(bus_addr), .wdata_in(bus_wdata),
    .cs_out(rb_cs), .we_out(rb_we), .addr_out(rb_addr), .wdata_out(rb_wdata),
    .rdata_in(rb_rdata), .rvalid_in(rb_rvalid),
    .rdata_out(bus_rdata), .rvalid_out(bus_rvalid),
    .soft_lock(soft_lock), .session_open(dbgen)
  );

  // --------------- Decode ------------------------
  wire in_sfr = (rb_addr < 16'h0100);

  // --------------- AUTH FSM ----------------------
  logic [255:0] pk_in_bus, pk_allow_shadow_bus;
  logic         auth_start_pulse, reset_fsm_pulse, debug_done_pulse;
  logic         fsm_busy, fsm_done, fsm_pk_match, fsm_pass;

  auth_fsm_plain #(.PKW(256)) u_auth (
    .clk      (pclk),
    .rst_n    (presetn),
    .start    (auth_start_pulse),
    .clear    (reset_fsm_pulse | debug_done_pulse),
    .pk_input (pk_in_bus),
    .pk_allow (pk_allow_shadow_bus),
    .busy     (fsm_busy),
    .done     (fsm_done),
    .pk_match (fsm_pk_match),
    .pass     (fsm_pass)
  );

  // --------------- Regfile (SFR) -----------------
  logic [31:0]  rf_rdata;  logic rf_rvalid;

  jtag_mailbox_regfile #(.AW(16)) u_regfile (
    .clk(pclk), .rst_n(presetn),
    .bus_cs   (in_sfr ? rb_cs   : 1'b0),
    .bus_we   (in_sfr ? rb_we   : 1'b0),
    .bus_addr (rb_addr),
    .bus_wdata(rb_wdata),
    .bus_rdata(rf_rdata),
    .bus_rvalid(rf_rvalid),
    .pk_in_o            (pk_in_bus),
    .pk_allow_shadow_o  (pk_allow_shadow_bus),
    .auth_start_pulse   (auth_start_pulse),
    .reset_fsm_pulse    (reset_fsm_pulse),
    .debug_done_pulse   (debug_done_pulse),
    .busy_i             (fsm_busy),
    .done_i             (fsm_done),
    .pk_match_i         (fsm_pk_match),
    .auth_pass_i        (fsm_pass),
    .why_denied_i       (why_denied),
    .dbgen_i            (dbgen),
    .soft_lock_o        (soft_lock),
    .lcs_o              (lcs),
    .tzpc_o             (tzpc),
    .domain_o           (domain),
    .access_lv_o        (access_lv),
    .bypass_en_o        (bypass_en)
  );

  // --------------- OTP CMD Host (PMOD) -----------
  logic        host_pready;  logic [31:0] host_prdata;

  // NOTE: PMOD 모드 - loopback 경로 미사용, 외부 보드2가 응답
  otp_client_apb #(.AW(16), .USE_PMOD(1'b1)) u_otp_host (
    .pclk(pclk), .presetn(presetn),
    .psel   (in_sfr ? rb_cs : 1'b0),
    .penable(in_sfr ? (rb_we | ~rb_we) : 1'b0),
    .pwrite (in_sfr ? rb_we : 1'b0),
    .paddr  ({16'h0, rb_addr}),
    .pwdata (rb_wdata),
    .prdata (host_prdata),
    .pready (host_pready),
    .otp_sclk(otp_sclk),
    .otp_req (otp_req),
    .otp_ack (otp_ack),
    .otp_din (otp_din),
    .lb_cmd_valid(), .lb_cmd_code(), .lb_data_valid(), .lb_data_nib()
  );

  // --------------- MEM (0x100~) ------------------
  logic [31:0] mem [0:255];  wire [7:0] widx = rb_addr[9:2];
  initial begin
    integer i; for (i=0;i<256;i=i+1) mem[i]=32'h0; mem[8'h40]=32'hABCD_1234;
  end
  logic [31:0] mem_rdata; logic mem_rvalid;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin mem_rvalid<=1'b0; mem_rdata<=32'h0; end
    else begin
      if (~in_sfr && rb_cs && rb_we)                mem[widx] <= rb_wdata;
      mem_rvalid <= (~in_sfr && rb_cs && ~rb_we);
      if (~in_sfr && rb_cs && ~rb_we)               mem_rdata <= mem[widx];
    end
  end

  // ------------- SFR return mux (host win) -------
  wire host_sfr_sel = in_sfr && (rb_addr >= 16'h0090) && (rb_addr <= 16'h009C);
  wire [31:0] sfr_rdata  = host_sfr_sel ? host_prdata  : rf_rdata;
  wire        sfr_rvalid = host_sfr_sel ? host_pready  : rf_rvalid;

  // ------------- Return mux -> Filter ------------
  assign rb_rdata  = in_sfr ? sfr_rdata : mem_rdata;
  assign rb_rvalid = in_sfr ? sfr_rvalid: mem_rvalid;

  // --------------- Policy ------------------------
  access_policy u_policy (
    .soft_lock (soft_lock),
    .lcs       (lcs),
    .tzpc      (tzpc),
    .domain    (domain),
    .access_lv (access_lv),
    .auth_pass (fsm_pass),
    .bypass_en (bypass_en),
    .dbgen     (dbgen),
    .why_denied(why_denied)
  );

  // --------------- LEDs --------------------------
  assign led[3] = 1'b1;
  assign led[2:0] = 3'b000;
  assign led0_g = dbgen;
  assign led0_r = ~dbgen;
  assign led1_r = soft_lock;
  assign led1_b = ~soft_lock;

endmodule
