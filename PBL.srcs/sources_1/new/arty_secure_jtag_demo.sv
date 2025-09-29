// arty_secure_jtag_axi_demo.sv
`timescale 1ns/1ps
module arty_secure_jtag_axi_demo (
  input  logic        CLK100MHZ,      // Arty A7 100MHz
  input  logic [3:0]  btn,            // btn[0]=reset only (optional)
  output logic [3:0]  led,            // led3=default ON, led[2:0]=사용자 표시
  // RGB LED0/1 (XDC에 이미 핀 존재)
  output logic        led0_r, led0_g, /*led0_b unused*/
  output logic        led1_r, /*led1_g unused*/ led1_b
);
  import secure_jtag_pkg::*;

  // ---- clock/reset ----
  logic rst_n;
  assign rst_n = ~btn[0]; // BTN0 누르면 reset

  // ---------------- 보드 클럭/리셋 ----------------
  wire aclk    = CLK100MHZ;
  wire aresetn = ~btn[0];   // 버튼 놓으면 1(리셋 해제)
  // ---- AXI <-> APB bridge ----
  // JTAG-to-AXI Master IP (IP Catalog에서 추가, 인스턴스명 고정)
  //   Ports (Vivado가 생성): jtag_axi_0_M_AXI_*
  //   Clock: aclk 입력 필요 (CLK100MHZ 사용)
  // (* keep_hierarchy = "yes" *)  // (Vivado naming 안정용 선택)
  wire [31:0] m_axi_awaddr, m_axi_wdata, m_axi_araddr, m_axi_rdata;
  wire        m_axi_awvalid, m_axi_awready;
  wire  [3:0] m_axi_wstrb;
  wire        m_axi_wvalid,  m_axi_wready;
  wire  [1:0] m_axi_bresp;
  wire        m_axi_bvalid,  m_axi_bready;
  wire        m_axi_arvalid, m_axi_arready;
  wire  [1:0] m_axi_rresp;
  wire        m_axi_rvalid,  m_axi_rready;

  // jtag_axi_0 (XCI/IP 인스턴스) 포트 명칭 예시 - Vivado 생성 이름에 맞춰 연결
  jtag_axi_0 jtag_axi_i (
    .aclk          (CLK100MHZ),
    .aresetn       (rst_n),
    .m_axi_awaddr  (m_axi_awaddr),
    .m_axi_awprot  (),                 // 사용 안 함
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
    .m_axi_arprot  (),                 // 사용 안 함
    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_rdata   (m_axi_rdata),
    .m_axi_rresp   (m_axi_rresp),
    .m_axi_rvalid  (m_axi_rvalid),
    .m_axi_rready  (m_axi_rready)
  );

  // ---- AXI-Lite → APB ----
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

  // ---- Secure JTAG APB Top (기존) ----
  logic dbg_enable;
  top_secure_jtag_with_auth_apb u_core (
    .pclk    (CLK100MHZ),
    .presetn (rst_n),
    .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata), .prdata(prdata),
    .pready(pready), .pslverr(),   // pslverr는 미사용
    .dbg_enable_o(dbg_enable)
  );

  // ---- LED 표시 ----
  // 기본 정책:
  //  - led3: 항상 ON (보드 살아있음)
  //  - led0_r: debug disable(=~dbg_enable), led0_g: debug enable(=dbg_enable)
  //  - led1_r: soft_lock=1 (PRD/LOCK), led1_b: bypass(soft_lock=0)
  //  - led[0], led[1], led[2]는 필요시 확장. 여기선 led[2:0]=0.
  assign led[3] = 1'b1;
  assign led[2:0] = 3'b000;

  // 내부 SFR mirror를 직접 참조 (디자인 계층에 맞춰 경로 확인)
  wire soft_lock = u_core.u_core.u_reg.soft_lock_o; // 래핑 여부에 따라 경로 조정 필요
  // 만약 위 경로가 다르면: u_core.u_reg.soft_lock_o 또는 u_core.u_regfile.soft_lock_o 등 네 소스에 맞게 바꿔줘.

  assign led0_g = dbg_enable;
  assign led0_r = ~dbg_enable;
  assign led1_r = soft_lock;        // 1=LOCK(빨강)
  assign led1_b = ~soft_lock;       // 0=BYPASS(파랑)

endmodule
