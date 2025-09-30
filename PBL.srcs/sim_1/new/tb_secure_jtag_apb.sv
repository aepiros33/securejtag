// tb_secure_jtag_apb.sv  (FINAL - ALL CASES)
`timescale 1ns/1ps

// TB 로컬 상수(패키지 의존 없이)
localparam logic [15:0] MEM_BASE_ADDR  = 16'h0100;  // 0x100 이상 메모리
localparam logic [31:0] BRAM_BASE      = 32'h0000_0100;
localparam logic [31:0] ADDR_STATUS    = 32'h0000_0004;
localparam logic [31:0] ADDR_TZPC      = 32'h0000_0044;
localparam logic [31:0] ADDR_BYPASS_EN = 32'h0000_0058;
localparam logic [31:0] ADDR_PK_ALLOW0 = 32'h0000_0060;
localparam logic [31:0] ADDR_SOFTLOCK  = 32'h0000_0080;
localparam logic [31:0] ADDR_LCS       = 32'h0000_0084;

// ─────────────────────────────────────────────────────────────────────────────
// 단순 BRAM 모델 (0x100~)
// ─────────────────────────────────────────────────────────────────────────────
module bram_model #(
  parameter int  AW       = 16,
  parameter logic [AW-1:0] MEM_BASE = 16'h0100
)(
  input  logic          clk, rst_n,
  input  logic          cs, we,
  input  logic [AW-1:0] addr,      // byte address
  input  logic [31:0]   wdata,
  output logic [31:0]   rdata,
  output logic          rvalid
);
  logic [31:0] mem [0:255];
  wire  [7:0] widx = addr[9:2];

  integer i;
  initial begin
    for (i=0; i<256; i++) mem[i] = 32'h0;
    mem[8'h40] = 32'hABCD_1234; // addr 0x100
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      rvalid <= 1'b0; rdata <= 32'h0;
    end else begin
      if (cs && we && (addr >= MEM_BASE)) mem[widx] <= wdata;
      rvalid <= cs && ~we && (addr >= MEM_BASE);
      if (cs && ~we && (addr >= MEM_BASE)) rdata <= mem[widx];
    end
  end
endmodule

// ─────────────────────────────────────────────────────────────────────────────
// TB TOP
// ─────────────────────────────────────────────────────────────────────────────
module tb_secure_jtag_apb;
  // clock/reset
  logic pclk=0, presetn=0;
  always #5 pclk = ~pclk; // 100MHz
  initial begin
    #50 presetn = 1;
  end

  // APB master ↔ bridge
  logic        psel, penable, pwrite;
  logic [31:0] paddr, pwdata, prdata;
  logic        pready, pslverr;

  // bridge → filter
  logic         bus_cs, bus_we;
  logic [15:0]  bus_addr;
  logic [31:0]  bus_wdata, bus_rdata;
  logic         bus_rvalid;

  // filter → downstream shared
  logic         rb_cs, rb_we;
  logic [15:0]  rb_addr;
  logic [31:0]  rb_wdata, rb_rdata;
  logic         rb_rvalid;

  // SFR 상태(레지스터 파일 출력)
  logic         soft_lock;
  logic [2:0]   lcs;
  logic [5:0]   tzpc;
  logic [3:0]   domain, access_lv;
  logic [7:0]   why_denied;
  logic         bypass_en;     // regfile → policy

  // 정책/세션
  logic         auth_pass = 1'b0;  // PK 인증 성공 플래그(테스트에서 토글)
  logic         dbgen;             // = session_open 로 사용

  // 디버그용 변수
  logic [31:0]  v;

  // 1) 브리지 (원본 핸드셰이크 유지)
  apb_reg_bridge #(.AW(16)) u_bridge (
    .pclk(pclk), .presetn(presetn),
    .psel(psel), .penable(penable), .pwrite(pwrite),
    .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .bus_cs(bus_cs), .bus_we(bus_we), .bus_addr(bus_addr),
    .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_rvalid(bus_rvalid)
  );

  // 2) LOCK 필터 (LOCK && addr>=0x100 → READ=0, WRITE drop)
  regbus_filter_prepost #(.AW(16)) u_filter (
    .clk(pclk), .rst_n(presetn),
    .cs_in(bus_cs), .we_in(bus_we), .addr_in(bus_addr), .wdata_in(bus_wdata),
    .cs_out(rb_cs), .we_out(rb_we), .addr_out(rb_addr), .wdata_out(rb_wdata),
    .rdata_in(rb_rdata), .rvalid_in(rb_rvalid),
    .rdata_out(bus_rdata), .rvalid_out(bus_rvalid),
    .soft_lock(soft_lock), .session_open(dbgen)  // 정책의 dbgen 사용
  );

  // 3) SFR vs MEM 디코드
  wire in_sfr = (rb_addr < MEM_BASE_ADDR);

  // 4) 실제 regfile
  logic [255:0] pk_in_bus, pk_allow_shadow_bus;
  logic         auth_start_pulse, reset_fsm_pulse, debug_done_pulse;
  logic         rf_rvalid;
  logic [31:0]  rf_rdata;

  jtag_mailbox_regfile #(.AW(16)) u_rf (
    .clk(pclk), .rst_n(presetn),

    .bus_cs   (in_sfr ? rb_cs   : 1'b0),
    .bus_we   (in_sfr ? rb_we   : 1'b0),
    .bus_addr (rb_addr),
    .bus_wdata(rb_wdata),
    .bus_rdata(rf_rdata),
    .bus_rvalid(rf_rvalid),

    .lcs_o   (lcs),
    .dbgen_i (dbgen),
    .pk_match_i(1'b0),
    .sig_valid_i(1'b1),
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
    .bypass_en_o(bypass_en)              // ★ BYPASS_EN 노출
  );

  // 5) 메모리(0x100~)
  logic [31:0] mem_rdata; logic mem_rvalid;
  bram_model #(.AW(16), .MEM_BASE(MEM_BASE_ADDR)) u_mem (
    .clk(pclk), .rst_n(presetn),
    .cs(~in_sfr ? rb_cs : 1'b0),
    .we(~in_sfr ? rb_we : 1'b0),
    .addr(rb_addr),
    .wdata(rb_wdata),
    .rdata(mem_rdata),
    .rvalid(mem_rvalid)
  );

  // 6) read mux (SFR/MEM → 필터로 back)
  assign rb_rdata  = in_sfr ? rf_rdata  : mem_rdata;
  assign rb_rvalid = in_sfr ? rf_rvalid : mem_rvalid;

  // 7) 정책 → dbgen(=session_open)
  access_policy u_policy (
    .soft_lock (soft_lock),
    .lcs       (lcs),
    .tzpc      (tzpc),
    .domain    (domain),
    .access_lv (access_lv),
    .auth_pass (auth_pass),
    .bypass_en (bypass_en),   // ★ 연결
    .dbgen     (dbgen),
    .why_denied(why_denied)
  );

  // ── APB Master BFM (blocking) ──
  task apb_write(input [31:0] a, input [31:0] d);
    @(posedge pclk);
    psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
    @(posedge pclk);
    penable = 1;
    wait (pready==1);
    @(posedge pclk);
    psel = 0; penable = 0; pwrite = 0;
  endtask

  task apb_read(input [31:0] a, output [31:0] d);
    @(posedge pclk);
    psel = 1; pwrite = 0; paddr = a; penable = 0;
    @(posedge pclk);
    penable = 1;
    wait (pready==1);
    d = prdata;
    @(posedge pclk);
    psel = 0; penable = 0;
  endtask

  function void expect_eq (string label, logic [31:0] got, logic [31:0] exp);
    if (got!==exp) $display("%s  FAIL got=%h expect=%h", label, got, exp);
    else           $display("%s  PASS got=%h", label, got);
  endfunction

  // ── Final Test Sequence ──
  initial begin
    logic [31:0] v0;

    // init
    psel=0; penable=0; pwrite=0; paddr='0; pwdata='0;

    @(posedge presetn); repeat(2) @(posedge pclk);

    // 1) Basic SFR reads
    apb_read(ADDR_STATUS,   v);  $display("STATUS   = %h", v);
    apb_read(ADDR_SOFTLOCK, v);  $display("SOFTLOCK = %h", v);
    apb_read(ADDR_LCS,      v);  $display("LCS      = %h", v);

    // 2) TZPC write-back
    apb_write(ADDR_TZPC, 32'hA5A5_A5A5);
    apb_read (ADDR_TZPC, v);     expect_eq("TZPC write-back", v, 32'hA5A5_A5A5);

    // 3) SOFTLOCK toggle
    apb_write(ADDR_SOFTLOCK, 32'h0);
    apb_read (ADDR_SOFTLOCK, v); expect_eq("SOFTLOCK -> 0", v, 32'h0);
    apb_write(ADDR_SOFTLOCK, 32'h1);
    apb_read (ADDR_SOFTLOCK, v); expect_eq("SOFTLOCK -> 1", v, 32'h1);

    // 4) UNLOCK → MEM R/W
    apb_write(ADDR_SOFTLOCK, 32'h0);
    apb_write(BRAM_BASE+32'h0, 32'h1122_3344);
    apb_read (BRAM_BASE+32'h0, v);  $display("UNLOCK read @+0 = %h", v);
    apb_read (BRAM_BASE+32'h4, v);  $display("UNLOCK read @+4 = %h", v);

    // 5) LOCK → 0x100~ 차단 (READ=0)
    apb_write(ADDR_SOFTLOCK, 32'h1);
    apb_read (BRAM_BASE+32'h0, v);  expect_eq("LOCK read @+0", v, 32'h0);
    apb_read (BRAM_BASE+32'h4, v);  expect_eq("LOCK read @+4", v, 32'h0);

    // 6) BYPASS (DEV에서만 유효): BYPASS_EN=1 → session open
    apb_write(ADDR_BYPASS_EN, 32'h1);
    @(posedge pclk);
    apb_read (BRAM_BASE+32'h0, v0); $display("BYPASS read @+0 = %h (expect 11223344)", v0);
    apb_read (BRAM_BASE+32'h4, v0); $display("BYPASS read @+4 = %h", v0);
    apb_write(ADDR_BYPASS_EN, 32'h0);
    @(posedge pclk);

    // 7) AUTH PASS 케이스: soft_lock=1 유지 + auth_pass=1 → session open
    apb_write(ADDR_SOFTLOCK, 32'h1);
    auth_pass = 1'b1;
    @(posedge pclk);
    apb_read (BRAM_BASE+32'h0, v0); $display("AUTH PASS read @+0 = %h (expect 11223344)", v0);
    apb_read (BRAM_BASE+32'h4, v0); $display("AUTH PASS read @+4 = %h", v0);
    auth_pass = 1'b0;

    // 8) DEV에서 PK_ALLOW0 R/W
    apb_read (ADDR_LCS, v);        $display("LCS=%h (DEV=2)", v);
    apb_write(ADDR_PK_ALLOW0, 32'hDEAD_BEEF);
    apb_read (ADDR_PK_ALLOW0, v);  expect_eq("PK_ALLOW0 write-back", v, 32'hDEAD_BEEF);

    $display("DONE.");
    #50 $finish;
  end
endmodule
