// arty_secure_jtag_axi_demo.sv
`timescale 1ns/1ps
module arty_secure_jtag_axi_demo (
  input  logic        CLK100MHZ,      // Arty A7 100MHz
  input  logic [3:0]  btn,            // btn[0]=reset only (optional)
  output logic [3:0]  led,            // led3=default ON, led[2:0]=����� ǥ��
  // RGB LED0/1 (XDC�� �̹� �� ����)
  output logic        led0_r, led0_g, /*led0_b unused*/
  output logic        led1_r, /*led1_g unused*/ led1_b
);
  import secure_jtag_pkg::*;

  // ---- clock/reset ----
  logic rst_n;
  assign rst_n = ~btn[0]; // BTN0 ������ reset

  // ---------------- ���� Ŭ��/���� ----------------
  wire aclk    = CLK100MHZ;
  wire aresetn = ~btn[0];   // ��ư ������ 1(���� ����)
  // ---- AXI <-> APB bridge ----
  // JTAG-to-AXI Master IP (IP Catalog���� �߰�, �ν��Ͻ��� ����)
  //   Ports (Vivado�� ����): jtag_axi_0_M_AXI_*
  //   Clock: aclk �Է� �ʿ� (CLK100MHZ ���)
  // (* keep_hierarchy = "yes" *)  // (Vivado naming ������ ����)
  wire [31:0] m_axi_awaddr, m_axi_wdata, m_axi_araddr, m_axi_rdata;
  wire        m_axi_awvalid, m_axi_awready;
  wire  [3:0] m_axi_wstrb;
  wire        m_axi_wvalid,  m_axi_wready;
  wire  [1:0] m_axi_bresp;
  wire        m_axi_bvalid,  m_axi_bready;
  wire        m_axi_arvalid, m_axi_arready;
  wire  [1:0] m_axi_rresp;
  wire        m_axi_rvalid,  m_axi_rready;

  // jtag_axi_0 (XCI/IP �ν��Ͻ�) ��Ʈ ��Ī ���� - Vivado ���� �̸��� ���� ����
  jtag_axi_0 jtag_axi_i (
    .aclk          (CLK100MHZ),
    .aresetn       (rst_n),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awprot  (),                 // ��� �� ��
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
    .m_axi_arprot  (),                 // ��� �� ��
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready)
  );

  // ---- AXI-Lite �� APB ----
  logic        psel, penable, pwrite, pready;
  logic [31:0] paddr, pwdata, prdata;

  axi_lite2apb_bridge #(.AW(16), .AXI_BASE(32'h4000_0000)) u_ax2apb (
    .aclk          (CLK100MHZ),
    .aresetn       (rst_n),
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

  // ---- Secure JTAG APB Top (����) ----
  logic dbg_enable;
  top_secure_jtag_with_auth_apb u_core (
    .pclk    (CLK100MHZ),
    .presetn (rst_n),
    .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata), .prdata(prdata),
    .pready(pready), .pslverr(),   // pslverr�� �̻��
    .dbg_enable_o(dbg_enable)
  );

  // ---- LED ǥ�� ----
  // �⺻ ��å:
  //  - led3: �׻� ON (���� �������)
  //  - led0_r: debug disable(=~dbg_enable), led0_g: debug enable(=dbg_enable)
  //  - led1_r: soft_lock=1 (PRD/LOCK), led1_b: bypass(soft_lock=0)
  //  - led[0], led[1], led[2]�� �ʿ�� Ȯ��. ���⼱ led[2:0]=0.
  assign led[3] = 1'b1;
  assign led[2:0] = 3'b000;

  // ���� SFR mirror�� ���� ���� (������ ������ ���� ��� Ȯ��)
  wire soft_lock = u_core.u_core.u_reg.soft_lock_o; // ���� ���ο� ���� ��� ���� �ʿ�
  // ���� �� ��ΰ� �ٸ���: u_core.u_reg.soft_lock_o �Ǵ� u_core.u_regfile.soft_lock_o �� �� �ҽ��� �°� �ٲ���.

  assign led0_g = dbg_enable;
  assign led0_r = ~dbg_enable;
  assign led1_r = soft_lock;        // 1=LOCK(����)
  assign led1_b = ~soft_lock;       // 0=BYPASS(�Ķ�)

endmodule
