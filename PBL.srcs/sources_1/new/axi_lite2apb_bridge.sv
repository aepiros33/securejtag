// axi_lite2apb_bridge.sv
`timescale 1ns/1ps
module axi_lite2apb_bridge #(
  parameter int AW = 16,                // APB 주소폭(하위 비트 사용)
  parameter logic [31:0] AXI_BASE = 32'h4000_0000 // 베이스(툴 쪽 가독용)
)(
  input  logic         aclk,
  input  logic         aresetn,

  // AXI4-Lite slave
  input  logic [31:0]  s_axi_awaddr,
  input  logic         s_axi_awvalid,
  output logic         s_axi_awready,

  input  logic [31:0]  s_axi_wdata,
  input  logic [3:0]   s_axi_wstrb,
  input  logic         s_axi_wvalid,
  output logic         s_axi_wready,

  output logic [1:0]   s_axi_bresp,
  output logic         s_axi_bvalid,
  input  logic         s_axi_bready,

  input  logic [31:0]  s_axi_araddr,
  input  logic         s_axi_arvalid,
  output logic         s_axi_arready,

  output logic [31:0]  s_axi_rdata,
  output logic [1:0]   s_axi_rresp,
  output logic         s_axi_rvalid,
  input  logic         s_axi_rready,

  // APB master
  output logic         psel,
  output logic         penable,
  output logic         pwrite,
  output logic [31:0]  paddr,    // APB는 16b만 쓰지만 정렬을 위해 32b로 뽑음
  output logic [31:0]  pwdata,
  input  logic [31:0]  prdata,
  input  logic         pready
);
  // 간단: AXI Lite 단일비트 응답(OKAY=2'b00), 1-트랜잭션 파이프라인
  typedef enum logic [2:0] {IDLE, W_ACC, W_WAIT, W_RESP, R_ACC, R_WAIT, R_RESP} state_e;
  state_e st;

  // latched
  logic [31:0] awaddr_q, araddr_q, wdata_q;
  logic        aw_hs, w_hs, ar_hs;

  // AXI 핸드쉐이크
  assign aw_hs = s_axi_awvalid & s_axi_awready;
  assign w_hs  = s_axi_wvalid  & s_axi_wready;
  assign ar_hs = s_axi_arvalid & s_axi_arready;

  // 기본 AXI 응답
  always_comb begin
    s_axi_bresp  = 2'b00;  // OKAY
    s_axi_rresp  = 2'b00;  // OKAY
  end

  // AXI ready 기본값
  always_comb begin
    s_axi_awready = (st==IDLE);
    s_axi_wready  = (st==IDLE);
    s_axi_arready = (st==IDLE);
  end

  // APB 주소/데이터
  wire [31:0] awaddr_eff = s_axi_awaddr; // 베이스는 툴에서만 인지. RTL은 하위비트 사용
  wire [31:0] araddr_eff = s_axi_araddr;

  // APB state machine
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      st <= IDLE;
      {psel, penable, pwrite} <= '0;
      {s_axi_bvalid, s_axi_rvalid} <= '0;
      s_axi_rdata <= '0;
      awaddr_q <= '0; araddr_q <= '0; wdata_q <= '0;
    end else begin
      case (st)
        IDLE: begin
          s_axi_bvalid <= 1'b0;
          s_axi_rvalid <= 1'b0;
          if (s_axi_awvalid && s_axi_wvalid) begin
            // WRITE
            awaddr_q <= awaddr_eff;
            wdata_q  <= s_axi_wdata;
            // APB setup
            psel   <= 1'b1; penable <= 1'b0; pwrite <= 1'b1;
            paddr  <= {16'h0, awaddr_eff[AW-1:0]};
            pwdata <= s_axi_wdata;
            st     <= W_ACC;
          end else if (s_axi_arvalid) begin
            // READ
            araddr_q <= araddr_eff;
            psel   <= 1'b1; penable <= 1'b0; pwrite <= 1'b0;
            paddr  <= {16'h0, araddr_eff[AW-1:0]};
            st     <= R_ACC;
          end
        end
        W_ACC: begin
          penable <= 1'b1;    // enable phase
          st <= W_WAIT;
        end
        W_WAIT: begin
          if (pready) begin
            // complete
            psel <= 1'b0; penable <= 1'b0; pwrite <= 1'b0;
            s_axi_bvalid <= 1'b1;
            st <= W_RESP;
          end
        end
        W_RESP: begin
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            st <= IDLE;
          end
        end
        R_ACC: begin
          penable <= 1'b1;
          st <= R_WAIT;
        end
        R_WAIT: begin
          if (pready) begin
            s_axi_rdata <= prdata;
            psel <= 1'b0; penable <= 1'b0;
            s_axi_rvalid <= 1'b1;
            st <= R_RESP;
          end
        end
        R_RESP: begin
          if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            st <= IDLE;
          end
        end
        default: st <= IDLE;
      endcase
    end
  end
endmodule
