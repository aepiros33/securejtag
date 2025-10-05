// ============================================================================
// arty_secure_jtag_axi_demo_core.sv
// (FINAL v9) 
//  - APB SETUP-latched demux/mux for OTP SFRs (0x0090~0x009C, 0x00A0~0x00BC)
//  - Safe EXT trigger (SETUP ����ȣ �� ���� Ŭ�� 1�޽�) for otp_client_apb
//  - otp_client_apb v8 ����: DATA/CNT READ = H_LATCH+1 ���� ACK (�׻� �ֽ�)
//  - �� ���� ��� ����: auth_fsm_plain �� regfile ���ε�, WHY_DENIED=PK_MISMATCH ����
//  - regbus_filter_prepost.session_open = dbgen (access_policy ���)
// ============================================================================

`timescale 1ns/1ps
module arty_secure_jtag_axi_demo_core (
  input  logic        CLK100MHZ,
  input  logic [3:0]  btn,
  output logic [3:0]  led,
  output logic        led0_r, led0_g,
  output logic        led1_r, led1_b
);

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
    .aclk(pclk), .aresetn(presetn),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awprot(), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
    .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
    .m_axi_araddr(m_axi_araddr), .m_axi_arprot(), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  // ------------- AXI-Lite -> APB ----------------
  logic        apb_psel, apb_penable, apb_pwrite;
  logic [31:0] apb_paddr, apb_pwdata, apb_prdata_mux;
  logic        apb_pready_mux;

  axi_lite2apb_bridge #(.AW(16), .AXI_BASE(32'h4000_0000)) u_ax2apb (
    .aclk(pclk), .aresetn(presetn),
    .s_axi_awaddr(m_axi_awaddr), .s_axi_awvalid(m_axi_awvalid), .s_axi_awready(m_axi_awready),
    .s_axi_wdata(m_axi_wdata), .s_axi_wstrb(m_axi_wstrb), .s_axi_wvalid(m_axi_wvalid), .s_axi_wready(m_axi_wready),
    .s_axi_bresp(m_axi_bresp), .s_axi_bvalid(m_axi_bvalid), .s_axi_bready(m_axi_bready),
    .s_axi_araddr(m_axi_araddr), .s_axi_arvalid(m_axi_arvalid), .s_axi_arready(m_axi_arready),
    .s_axi_rdata(m_axi_rdata), .s_axi_rresp(m_axi_rresp), .s_axi_rvalid(m_axi_rvalid), .s_axi_rready(m_axi_rready),
    .psel(apb_psel), .penable(apb_penable), .pwrite(apb_pwrite),
    .paddr(apb_paddr), .pwdata(apb_pwdata),
    .prdata(apb_prdata_mux), .pready(apb_pready_mux)
  );

  // ---------------- APB decode (SETUP �� ��ġ) ----------------
  wire [15:0] a16_now   = apb_paddr[15:0];
  wire        in_sfr_now= (a16_now < 16'h0100);

  wire hit_cmd_now  = in_sfr_now && (a16_now == 16'h0090);
  wire hit_stat_now = in_sfr_now && (a16_now == 16'h0094);
  wire hit_data_now = in_sfr_now && (a16_now == 16'h0098);
  wire hit_cnt_now  = in_sfr_now && (a16_now == 16'h009C);
  wire hit_dbg_now  = in_sfr_now && (a16_now >= 16'h00A0 && a16_now <= 16'h00BC);
  wire host_hit_any_now = hit_cmd_now | hit_stat_now | hit_data_now | hit_cnt_now | hit_dbg_now;

  // SETUP ���� ����
  logic apb_psel_q;
  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) apb_psel_q <= 1'b0; else apb_psel_q <= apb_psel;
  end
  wire apb_setup = apb_psel & ~apb_psel_q;

  // �� SETUP���� �ּ�/����/�����̺꼱��/���ⵥ���� ��ġ
  logic [15:0] a16_lat;
  logic        apb_is_host_lat;
  logic        apb_write_lat;
  logic [31:0] pwdata_lat;

  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin
      a16_lat <= 16'h0; apb_is_host_lat <= 1'b0; apb_write_lat <= 1'b0; pwdata_lat <= 32'h0;
    end else if (apb_setup) begin
      a16_lat        <= a16_now;
      apb_is_host_lat<= host_hit_any_now;
      apb_write_lat  <= apb_pwrite;
      pwdata_lat     <= apb_pwdata;
    end
  end

  // ---------------- APB demux (SETUP-latched) ----------------
  // HOST(OTP) �����̺�
  wire host_psel    = apb_psel    &  apb_is_host_lat;
  wire host_penable = apb_penable &  apb_is_host_lat;
  wire host_pwrite  =               apb_is_host_lat ? apb_write_lat : 1'b0;

  // RF/MEM �����̺�
  wire rf_psel      = apb_psel    & ~apb_is_host_lat;
  wire rf_penable   = apb_penable & ~apb_is_host_lat;
  wire rf_pwrite    =              ~apb_is_host_lat ? apb_write_lat : 1'b0;

  // ---------------- apb_reg_bridge �� filter �� regfile/mem ----------------
  logic         bus_cs, bus_we;
  logic [15:0]  bus_addr;
  logic [31:0]  bus_wdata, bus_rdata;
  logic         bus_rvalid, pslverr_unused;
  logic [31:0]  rf_prdata; logic rf_pready;

  apb_reg_bridge #(.AW(16)) u_apb_bridge (
    .pclk(pclk), .presetn(presetn),
    .psel(rf_psel), .penable(rf_penable), .pwrite(rf_pwrite),
    .paddr({16'h0,a16_lat}), .pwdata(pwdata_lat),
    .prdata(rf_prdata), .pready(rf_pready), .pslverr(pslverr_unused),
    .bus_cs(bus_cs), .bus_we(bus_we),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata),
    .bus_rdata(bus_rdata), .bus_rvalid(bus_rvalid)
  );

  // -------- Filter �� Regfile/Mem (��å ����) --------
  logic         rb_cs, rb_we;
  logic [15:0]  rb_addr;
  logic [31:0]  rb_wdata, core_rdata;
  logic         core_rvalid;

  // policy �����/���� ��ȣ��
  logic         soft_lock, dbgen, bypass_en;
  logic [2:0]   lcs;
  logic [5:0]   tzpc;
  logic [3:0]   domain, access_lv;
  logic [7:0]   why_denied_wire; // policy�� ����� �̸��� Ȯ��(��� ����, �Ʒ� why_denied_auth ���)

  // ���� FSM �� regfile ��ȣ
  logic [255:0] pk_in_bus, pk_allow_shadow_bus;
  logic         auth_start_pulse, reset_fsm_pulse, debug_done_pulse;
  logic         fsm_busy, fsm_done, fsm_pk_match, fsm_pass;

  regbus_filter_prepost #(.AW(16)) u_filter (
    .clk(pclk), .rst_n(presetn),
    .cs_in(bus_cs), .we_in(bus_we), .addr_in(bus_addr), .wdata_in(bus_wdata),
    .cs_out(rb_cs), .we_out(rb_we), .addr_out(rb_addr), .wdata_out(rb_wdata),
    .rdata_in(core_rdata), .rvalid_in(core_rvalid),
    .rdata_out(bus_rdata), .rvalid_out(bus_rvalid),
    .soft_lock(soft_lock), .session_open(dbgen)   // �� DBGEN�� ������ �޸�/�������� ���� ���
  );

  // Regfile: ����/��å ��������/����
  logic [31:0] rf_rdata;  logic rf_rvalid;

  jtag_mailbox_regfile #(.AW(16)) u_regfile (
    .clk(pclk), .rst_n(presetn),
    .bus_cs   (rb_cs),
    .bus_we   (rb_we),
    .bus_addr (rb_addr),
    .bus_wdata(rb_wdata),
    .bus_rdata(rf_rdata),
    .bus_rvalid(rf_rvalid),

    // --- ���� ��� ���ε� ---
    .pk_in_o            (pk_in_bus),
    .pk_allow_shadow_o  (pk_allow_shadow_bus),
    .auth_start_pulse   (auth_start_pulse),
    .reset_fsm_pulse    (reset_fsm_pulse),
    .debug_done_pulse   (debug_done_pulse),
    .busy_i             (fsm_busy),
    .done_i             (fsm_done),
    .pk_match_i         (fsm_pk_match),
    .auth_pass_i        (fsm_pass),
    .why_denied_i       (why_denied_auth),  // �� �Ʒ����� ���� ����

    // --- ��å/����/ȯ�� ---
    .dbgen_i            (dbgen),
    .soft_lock_o        (soft_lock),
    .lcs_o              (lcs),
    .tzpc_o             (tzpc),
    .domain_o           (domain),
    .access_lv_o        (access_lv),
    .bypass_en_o        (bypass_en)
  );

  // ���� FSM (�ܼ� �� ���)
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

  // WHY_DENIED ����: PK �̽���ġ�� ���(0x08)
  // (��å why_denied_wire�� ����; �ʿ�� OR�ص� ��)
  logic [7:0] why_denied_auth;
  always_comb begin
    // DONE�� �������� ��ġ ���и� WD_PK_MISMATCH(=0x08) ��Ʈ
    if (fsm_done && !fsm_pk_match)       why_denied_auth = 8'h08;
    else                                 why_denied_auth = 8'h00;
  end

  // ��å ���: DBGEN ���� �� (����ü�� ����)
  access_policy u_policy (
    .soft_lock (soft_lock),
    .lcs       (lcs),
    .tzpc      (tzpc),
    .domain    (domain),
    .access_lv (access_lv),
    .auth_pass (fsm_pass),   // �� PASS�� ���� ����/DBGEN �Ǵܿ� ��
    .bypass_en (bypass_en),
    .dbgen     (dbgen),
    .why_denied(why_denied_wire) // �����(����� �̻��)
  );

  // ---------------- MEM (0x100~) ------------------
  logic [31:0] mem [0:255];  wire [7:0] widx = rb_addr[9:2];
  initial begin integer i; for(i=0;i<256;i=i+1) mem[i]=32'h0; mem[8'h40]=32'hABCD_1234; end
  logic [31:0] mem_rdata; logic mem_rvalid;
  wire in_mem = (rb_addr >= 16'h0100);

  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin mem_rvalid<=1'b0; mem_rdata<=32'h0; end
    else begin
      if (in_mem && rb_cs && rb_we)  mem[widx] <= rb_wdata;
      mem_rvalid <= (in_mem && rb_cs && ~rb_we);
      if (in_mem && rb_cs && ~rb_we) mem_rdata <= mem[widx];
    end
  end

  // filter ���� ����
  assign core_rdata  = (rb_addr < 16'h0100) ? rf_rdata : mem_rdata;
  assign core_rvalid = (rb_addr < 16'h0100) ? rf_rvalid: mem_rvalid;

  // ---------------- OTP host (loopback) ----------------
  logic        host_pready;  logic [31:0] host_prdata;
  logic        lb_cmd_valid, lb_data_valid;
  logic [1:0]  lb_cmd_code;   logic [3:0]  lb_data_nib;

  // server debug taps
  logic        dev_cmd_seen;
  logic [1:0]  dev_cmd_code_q;
  logic        dev_data_valid;
  logic [3:0]  dev_data_nib;
  logic [1:0]  dev_dv_cnt;

  // === SAFE EXT trigger: "���� SETUP ����ȣ" �� ���� Ŭ�� 1�޽� ===
  wire host_cmd_setup_now = apb_setup               // �̹� ������ SETUP
                          & host_hit_any_now        // OTP �ּ�
                          & apb_pwrite              // ����
                          & (a16_now == 16'h0090);  // CMD ��������

  logic host_cmd_setup_q;
  logic [1:0] ext_cmd_code_r;

  always_ff @(posedge pclk or negedge presetn) begin
    if(!presetn) begin
      host_cmd_setup_q <= 1'b0;
      ext_cmd_code_r   <= 2'b00;
    end else begin
      host_cmd_setup_q <= host_cmd_setup_now;        // ���� Ŭ�� 1�޽�
      if (host_cmd_setup_now)
        ext_cmd_code_r <= apb_pwdata[1:0];           // �ڵ� ������
    end
  end

  wire        ext_cmd_fire = host_cmd_setup_q;
  wire [1:0]  ext_cmd_code = ext_cmd_code_r;

  // Client (otp_client_apb v8 ����)
  otp_client_apb #(.AW(16), .CMDW(2), .USE_PMOD(1'b0), .USE_EXT_TRIG(1'b1)) u_otp_host (
    .pclk(pclk), .presetn(presetn),
    .psel   (host_psel),
    .penable(host_penable),
    .pwrite (host_pwrite),
    .paddr  ({16'h0, a16_lat}),
    .pwdata (pwdata_lat),
    .prdata (host_prdata),
    .pready (host_pready),
    .otp_sclk(), .otp_req(), .otp_ack(1'b0), .otp_din(4'h0),
    .lb_cmd_valid (lb_cmd_valid),
    .lb_cmd_code  (lb_cmd_code),
    .lb_data_valid(lb_data_valid),
    .lb_data_nib  (lb_data_nib),
    .ext_cmd_fire (ext_cmd_fire),
    .ext_cmd_code (ext_cmd_code),
    .dev_cmd_seen  (dev_cmd_seen),
    .dev_cmd_code_q(dev_cmd_code_q),
    .dev_data_valid(dev_data_valid),
    .dev_data_nib  (dev_data_nib),
    .dev_dv_cnt    (dev_dv_cnt)
  );

  // Device (loopback)
  otp_server_link #(.CMDW(2), .USE_PMOD(1'b0)) u_otp_dev (
    .clk(pclk), .rst_n(presetn),
    .otp_sclk(), .otp_req(), .otp_ack(), .otp_dout(),
    .cmd_valid (lb_cmd_valid),
    .cmd_code  (lb_cmd_code),
    .data_valid(lb_data_valid),
    .data_nib  (lb_data_nib),
    .dev_cmd_seen  (dev_cmd_seen),
    .dev_cmd_code_q(dev_cmd_code_q),
    .dev_data_valid(dev_data_valid),
    .dev_data_nib  (dev_data_nib),
    .dev_dv_cnt    (dev_dv_cnt)
  );

  // ---------------- APB ���� MUX (SETUP-latched select) ----------------
  assign apb_prdata_mux = apb_is_host_lat ? host_prdata : rf_prdata;
  assign apb_pready_mux = apb_is_host_lat ? host_pready : rf_pready;

  // ---------------- LEDs ----------------
  assign led[3]=1'b1; assign led[2:0]=3'b000;
  assign led0_g=dbgen; assign led0_r=~dbgen;
  assign led1_r=soft_lock; assign led1_b=~soft_lock;

endmodule
