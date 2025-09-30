// arty_secure_jtag_axi_demo.sv  (FINAL TOP for board)
// JTAG-to-AXI -> AXI-Lite->APB -> apb_reg_bridge -> regbus_filter_prepost
//                -> decode(SFR/MEM) -> regfile/BRAM -> return mux -> filter -> bridge
`timescale 1ns/1ps
module arty_secure_jtag_axi_demo (
  input  logic        CLK100MHZ,      // Arty A7 100MHz
  input  logic [3:0]  btn,            // btn[0]=reset
  output logic [3:0]  led,            // led3 alive, led[2:0] user
  output logic        led0_r, led0_g, /*led0_b unused*/
  output logic        led1_r, /*led1_g unused*/ led1_b
);
  // ���� reset/clock ����
  wire pclk    = CLK100MHZ;
  wire presetn = ~btn[0];

  // ���� JTAG-to-AXI Master IP (Vivado���� ������ �ν��Ͻ���/��Ʈ�� �����ּ���) ����
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

  // ���� AXI-Lite -> APB Bridge (�� ������Ʈ�� u_ax2apb) ����
  logic        psel, penable, pwrite, pready;
  logic [31:0] paddr, pwdata, prdata;

  axi_lite2apb_bridge #(.AW(16), .AXI_BASE(32'h4000_0000)) u_ax2apb (
    .aclk          (pclk),
    .aresetn       (presetn),
    // AXI slave
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
    // APB master
    .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready)
  );

  // ���� APB -> simple bus bridge (�� SFR zero-wait ���� ��ġ�� ���� ���) ����
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

  // ���� LOCK ���� (��� �����̺� �� ���� ����Ʈ) ����
  logic         rb_cs, rb_we;
  logic [15:0]  rb_addr;
  logic [31:0]  rb_wdata, rb_rdata;
  logic         rb_rvalid;

  // ����/��å ��ȣ
  logic         soft_lock, dbgen;
  logic [2:0]   lcs;
  logic [5:0]   tzpc;
  logic [3:0]   domain, access_lv;
  logic [7:0]   why_denied;
  logic         bypass_en;
  logic         auth_pass;  assign auth_pass = 1'b0; // (�ʿ� �� FSM ����)

  regbus_filter_prepost #(.AW(16)) u_filter (
    .clk(pclk), .rst_n(presetn),
    .cs_in(bus_cs), .we_in(bus_we), .addr_in(bus_addr), .wdata_in(bus_wdata),
    .cs_out(rb_cs), .we_out(rb_we), .addr_out(rb_addr), .wdata_out(rb_wdata),
    .rdata_in(rb_rdata), .rvalid_in(rb_rvalid),
    .rdata_out(bus_rdata), .rvalid_out(bus_rvalid),
    .soft_lock(soft_lock), .session_open(dbgen)
  );

  // ���� ���ڵ�: SFR(0x000~0x0FF) vs MEM(0x100~) ����
  wire in_sfr = (rb_addr < 16'h0100);

  // ���� ���� �������� ���� ����
  logic [255:0] pk_in_bus, pk_allow_shadow_bus;
  logic         auth_start_pulse, reset_fsm_pulse, debug_done_pulse;
  logic [31:0]  rf_rdata;  logic rf_rvalid;

  jtag_mailbox_regfile #(.AW(16)) u_regfile (
    .clk(pclk), .rst_n(presetn),
    .bus_cs   (in_sfr ? rb_cs   : 1'b0),
    .bus_we   (in_sfr ? rb_we   : 1'b0),
    .bus_addr (rb_addr),
    .bus_wdata(rb_wdata),
    .bus_rdata(rf_rdata),
    .bus_rvalid(rf_rvalid),

    .lcs_o   (lcs),
    .dbgen_i (dbgen),
    .pk_match_i(1'b0),         // �׽�Ʈ �⺻ 0 (�ʿ� �� FSM ����)
    .sig_valid_i(1'b1),        // MVP: 1
    .auth_pass_i(auth_pass),
    .why_denied_i(why_denied),
    .busy_i(1'b0),
    .done_i(1'b0),

    .tzpc_o(tzpc),
    .domain_o(domain),
    .access_lv_o(access_lv),
    .pk_in_o(pk_in_bus),
    .pk_allow_shadow_o(pk_allow_shadow_bus),
    .auth_start_pulse(auth_start_pulse),
    .reset_fsm_pulse(reset_fsm_pulse),
    .debug_done_pulse(debug_done_pulse),
    .soft_lock_o(soft_lock),
    .bypass_en_o(bypass_en)
  );

  // ���� ���� BRAM (0x100~) - 1-cycle read latency ����
  logic [31:0] mem [0:255];
  wire  [7:0]  widx = rb_addr[9:2];

  // �ʱ� ����(����)
  initial begin
    integer i;
    for (i=0; i<256; i=i+1) mem[i] = 32'h0;
    mem[8'h40] = 32'hABCD_1234; // 0x100
  end

  logic [31:0] mem_rdata; logic mem_rvalid;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin
      mem_rvalid <= 1'b0;
      mem_rdata  <= 32'h0;
    end else begin
      if (~in_sfr && rb_cs && rb_we)                mem[widx] <= rb_wdata;
      mem_rvalid <= (~in_sfr && rb_cs && ~rb_we);   // 1-cycle
      if (~in_sfr && rb_cs && ~rb_we)               mem_rdata <= mem[widx];
    end
  end

  // ���� ���� mux �� ���ͷ� ����
  assign rb_rdata  = in_sfr ? rf_rdata  : mem_rdata;
  assign rb_rvalid = in_sfr ? rf_rvalid : mem_rvalid;

  // ���� ��å �� dbgen(session_open) ����
  access_policy u_policy (
    .soft_lock (soft_lock),
    .lcs       (lcs),
    .tzpc      (tzpc),
    .domain    (domain),
    .access_lv (access_lv),
    .auth_pass (auth_pass),
    .bypass_en (bypass_en),
    .dbgen     (dbgen),
    .why_denied(why_denied)
  );

  // ���� LED ǥ�� ����
  assign led[3] = 1'b1;
  assign led[2:0] = 3'b000;

  assign led0_g = dbgen;          // DEBUG ENABLE = green
  assign led0_r = ~dbgen;         // DEBUG DISABLE = red
  assign led1_r = soft_lock;      // 1=LOCK
  assign led1_b = ~soft_lock;     // 0=BYPASS

endmodule
