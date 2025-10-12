`timescale 1ns/1ps
module arty_secure_jtag_demo (
  input  logic        CLK100MHZ,       // 100 MHz
  input  logic [3:0]  btn,             // BTN0=reset(hold), BTN1=toggle SOFT_LOCK, BTN2=auth VALID, BTN3=auth INVALID
  output logic [3:0]  led,             // led[0]=auth_success, led[1]=auth_fail, led[2]=busy(optional), led[3]=default on
  output logic        led0_r,          // debug disable (=~dbg_enable)
  output logic        led0_g,          // debug enable
  output logic        led0_b,          // unused
  output logic        led1_r,          // soft lock (1)
  output logic        led1_g,          // unused
  output logic        led1_b           // bypass (soft_lock=0)
);
  import secure_jtag_pkg::*;

  localparam logic [31:0] CMD_START = 32'h0000_0001;

  // Clock / Buttons
  wire clk = CLK100MHZ;
  logic [3:0] b_meta, b_sync, b_sync_d;
  always_ff @(posedge clk) begin
    b_meta   <= btn;
    b_sync   <= b_meta;
    b_sync_d <= b_sync;
  end
  wire [3:0] btn_rise =  b_sync & ~b_sync_d;  // rising edge
  wire       presetn  = ~b_sync[0];           // BTN0 hold=reset

  // APB wires
  logic         psel, penable, pwrite;
  logic [31:0]  paddr, pwdata, prdata;
  logic         pready, pslverr;
  logic         dbg_enable_o;

  top_secure_jtag_with_auth_apb u_core (
    .pclk        (clk),
    .presetn     (presetn),
    .psel        (psel),
    .penable     (penable),
    .pwrite      (pwrite),
    .paddr       (paddr),
    .pwdata      (pwdata),
    .prdata      (prdata),
    .pready      (pready),
    .pslverr     (pslverr),
    .dbg_enable_o(dbg_enable_o)
  );

  // Simple APB master FSM
  typedef enum logic [4:0] {
    ST_IDLE,
    ST_W_SETUP, ST_W_ENABLE,
    ST_R_SETUP, ST_R_ENABLE, ST_R_WAIT
  } state_e;

  // regs (current)
  state_e      st;
  logic        psel_q, penable_q, pwrite_q;
  logic [31:0] paddr_q, pwdata_q;

  logic [31:0] reg_waddr, reg_wdata, reg_raddr;

  logic [3:0]  pk_idx;
  logic        init_done;
  logic        busy_led;
  logic        auth_success, auth_fail;
  logic        soft_lock_state;
  logic        do_invalid;               // BTN2=0(VALID), BTN3=1(INVALID)

  // next
  state_e      st_n;
  logic        psel_n, penable_n, pwrite_n;
  logic [31:0] paddr_n, pwdata_n;

  logic [31:0] reg_waddr_n, reg_wdata_n, reg_raddr_n;

  logic [3:0]  pk_idx_n;
  logic        init_done_n;
  logic        busy_led_n;
  logic        auth_success_n, auth_fail_n;
  logic        soft_lock_state_n;
  logic        do_invalid_n;

  logic [3:0]  rd_index, wrote_index;

  // Next-state comb
  always_comb begin
    // defaults
    st_n          = st;

    psel_n        = 1'b0;
    penable_n     = 1'b0;
    pwrite_n      = 1'b0;
    paddr_n       = paddr_q;
    pwdata_n      = pwdata_q;

    reg_waddr_n   = reg_waddr;
    reg_wdata_n   = reg_wdata;
    reg_raddr_n   = reg_raddr;

    pk_idx_n          = pk_idx;
    init_done_n       = init_done;
    busy_led_n        = busy_led;
    auth_success_n    = auth_success;
    auth_fail_n       = auth_fail;
    soft_lock_state_n = soft_lock_state;
    do_invalid_n      = do_invalid;

    unique case (st)
      ST_IDLE: begin
        if (!init_done) begin
          // 정책 기본값 세팅
          reg_waddr_n = ADDR_TZPC;     reg_wdata_n = 32'h0000_003F;
          psel_n=1'b1; pwrite_n=1'b1; penable_n=1'b0; paddr_n=reg_waddr_n; pwdata_n=reg_wdata_n;
          st_n = ST_W_SETUP;
          init_done_n = 1'b1;
        end
        else if (btn_rise[1]) begin
          // toggle soft_lock
          reg_raddr_n = ADDR_SOFTLOCK;
          psel_n=1'b1; pwrite_n=1'b0; penable_n=1'b0; paddr_n=reg_raddr_n;
          busy_led_n = 1'b1;
          st_n = ST_R_SETUP;
        end
        else if (btn_rise[2]) begin
          // === VALID AUTH ===
          if (soft_lock_state==1'b0) begin
            // BYPASS에서는 인증 시도 스킵
            busy_led_n     = 1'b0;
            auth_success_n = 1'b0;
            auth_fail_n    = 1'b0;
            st_n = ST_IDLE;
          end else begin
            reg_raddr_n    = ADDR_PK_ALLOW0;
            pk_idx_n       = 4'd0;
            do_invalid_n   = 1'b0;       // VALID
            auth_success_n = 1'b0;
            auth_fail_n    = 1'b0;
            psel_n=1'b1; pwrite_n=1'b0; penable_n=1'b0; paddr_n=reg_raddr_n;
            busy_led_n = 1'b1;
            st_n = ST_R_SETUP;
          end
        end
        else if (btn_rise[3]) begin
          // === INVALID AUTH ===
          if (soft_lock_state==1'b0) begin
            // BYPASS에서는 인증 시도 스킵
            busy_led_n     = 1'b0;
            auth_success_n = 1'b0;
            auth_fail_n    = 1'b0;
            st_n = ST_IDLE;
          end else begin
            reg_raddr_n    = ADDR_PK_ALLOW0;
            pk_idx_n       = 4'd0;
            do_invalid_n   = 1'b1;       // INVALID
            auth_success_n = 1'b0;
            auth_fail_n    = 1'b0;
            psel_n=1'b1; pwrite_n=1'b0; penable_n=1'b0; paddr_n=reg_raddr_n;
            busy_led_n = 1'b1;
            st_n = ST_R_SETUP;
          end
        end
      end

      ST_W_SETUP: begin
        psel_n=1'b1; pwrite_n=1'b1; penable_n=1'b1; paddr_n=reg_waddr_n; pwdata_n=reg_wdata_n;
        st_n = ST_W_ENABLE;
      end

      // START 쓰기 후 곧장 STATUS 폴링으로 진입
      ST_W_ENABLE: begin
        if (reg_waddr == ADDR_TZPC && reg_wdata == 32'h0000_003F) begin
          reg_waddr_n = ADDR_DOMAIN;  reg_wdata_n = 32'h0000_0001;
          psel_n=1'b1; pwrite_n=1'b1; penable_n=1'b0; paddr_n=reg_waddr_n; pwdata_n=reg_wdata_n;
          st_n = ST_W_SETUP;
        end
        else if (reg_waddr == ADDR_DOMAIN && reg_wdata == 32'h0000_0001) begin
          reg_waddr_n = ADDR_ACCESS_LV;  reg_wdata_n = 32'h0000_0004;
          psel_n=1'b1; pwrite_n=1'b1; penable_n=1'b0; paddr_n=reg_waddr_n; pwdata_n=reg_wdata_n;
          st_n = ST_W_SETUP;
        end
        else if (reg_waddr == ADDR_CMD && reg_wdata == CMD_START) begin
          reg_raddr_n = ADDR_STATUS;                 // STATUS 폴링 시작
          psel_n=1'b1; pwrite_n=1'b0; penable_n=1'b0; paddr_n=reg_raddr_n;
          busy_led_n = 1'b1;
          st_n = ST_R_SETUP;
        end
        else begin
          st_n = ST_IDLE;
        end
      end

      ST_R_SETUP:  begin psel_n=1'b1; pwrite_n=1'b0; penable_n=1'b1; paddr_n=reg_raddr_n; busy_led_n=1'b1; st_n=ST_R_ENABLE; end
      ST_R_ENABLE: begin psel_n=1'b1; pwrite_n=1'b0; penable_n=1'b1; paddr_n=reg_raddr_n; busy_led_n=1'b1; st_n=ST_R_WAIT;   end
      ST_R_WAIT:   begin psel_n=1'b1; pwrite_n=1'b0; penable_n=1'b1; paddr_n=reg_raddr_n; busy_led_n=1'b1;                   end

      default: st_n = ST_IDLE;
    endcase
  end

  // Sequential
  always_ff @(posedge clk or negedge presetn) begin
    if (!presetn) begin
      st              <= ST_IDLE;

      psel_q          <= 1'b0;
      penable_q       <= 1'b0;
      pwrite_q        <= 1'b0;
      paddr_q         <= 32'h0;
      pwdata_q        <= 32'h0;

      reg_waddr       <= 32'h0;
      reg_wdata       <= 32'h0;
      reg_raddr       <= 32'h0;

      pk_idx          <= 4'd0;
      init_done       <= 1'b0;
      busy_led        <= 1'b0;
      auth_success    <= 1'b0;
      auth_fail       <= 1'b0;
      soft_lock_state <= 1'b1; // reset=LOCK 가정
      do_invalid      <= 1'b0;
    end else begin
      st       <= st_n;

      psel_q   <= psel_n;
      penable_q<= penable_n;
      pwrite_q <= pwrite_n;
      paddr_q  <= paddr_n;
      pwdata_q <= pwdata_n;

      reg_waddr<= reg_waddr_n;
      reg_wdata<= reg_wdata_n;
      reg_raddr<= reg_raddr_n;

      pk_idx          <= pk_idx_n;
      init_done       <= init_done_n;
      busy_led        <= busy_led_n;
      auth_success    <= auth_success_n;
      auth_fail       <= auth_fail_n;
      soft_lock_state <= soft_lock_state_n;
      do_invalid      <= do_invalid_n;

      // ----- Read path done -----
      if ((st == ST_R_ENABLE || st == ST_R_WAIT) && pready) begin
        logic [31:0] rd; rd = prdata;

        // SOFT_LOCK read -> toggle write (+ 로컬 미러 즉시 갱신)
        if (reg_raddr == ADDR_SOFTLOCK) begin
          soft_lock_state <= rd[0];         // 현재값 반영
          reg_waddr       <= ADDR_SOFTLOCK;
          reg_wdata       <= {31'h0, ~rd[0]};
          soft_lock_state <= ~rd[0];        // 즉시 반영 → 첫 클릭에 LED 전환
          st              <= ST_W_SETUP;
        end

        // PK_ALLOW -> PK_IN (word copy)
        else if (reg_raddr >= ADDR_PK_ALLOW0 && reg_raddr < (ADDR_PK_ALLOW0 + (8<<2))) begin
          rd_index  = (reg_raddr - ADDR_PK_ALLOW0) >> 2;
          reg_waddr <= ADDR_PK_IN0 + (rd_index << 2);
          reg_wdata <= (do_invalid && (rd_index==0)) ? (rd ^ 32'h0000_0001) : rd; // INVALID시 word0만 1비트 XOR
          st        <= ST_W_SETUP;
        end

        // STATUS polling
        else if (reg_raddr == ADDR_STATUS) begin
          if (rd[ST_DONE]) begin
            auth_success <= rd[ST_AUTH_PASS];      // PASS → led[0]
            auth_fail    <= (~rd[ST_AUTH_PASS]);   // FAIL → led[1]
            busy_led     <= 1'b0;
            st           <= ST_IDLE;
          end else begin
            reg_raddr <= ADDR_STATUS;              // 계속 폴링
            st        <= ST_R_SETUP;
          end
        end
      end

      // After writing PK_IN[i], request next word or START
      if (st == ST_W_ENABLE) begin
        if (reg_waddr >= ADDR_PK_IN0 && reg_waddr < (ADDR_PK_IN0 + (8<<2))) begin
          wrote_index = (reg_waddr - ADDR_PK_IN0) >> 2;
          if (wrote_index < 7) begin
            reg_raddr <= ADDR_PK_ALLOW0 + ((wrote_index + 1) << 2);
            st        <= ST_R_SETUP;
          end else begin
            // 마지막 워드 다음 START
            reg_waddr <= ADDR_CMD; 
            reg_wdata <= CMD_START;
            st        <= ST_W_SETUP;
          end
        end
      end

      if (st == ST_IDLE) busy_led <= 1'b0;
    end
  end

  // Drive APB
  assign psel    = psel_q;
  assign penable = penable_q;
  assign pwrite  = pwrite_q;
  assign paddr   = paddr_q;
  assign pwdata  = pwdata_q;

  // LEDs
  assign led[0] = auth_success;    // 인증 성공
  assign led[1] = auth_fail;       // 인증 실패
  assign led[2] = busy_led;        // busy
  assign led[3] = presetn;         // 기본 ON(리셋 해제 시 1)

  assign led0_g =  dbg_enable_o;         // debug enable
  assign led0_r = ~dbg_enable_o;         // debug disable
  assign led0_b = 1'b0;

  assign led1_r =  soft_lock_state;      // soft lock (1=RED)
  assign led1_g = 1'b0;
  assign led1_b = ~soft_lock_state;      // bypass (1=BLUE)
endmodule
