package secure_jtag_pkg;

  // ---------- Address Map (offsets) ----------
  localparam int unsigned ADDR_CMD        = 'h0000;
  localparam int unsigned ADDR_STATUS     = 'h0004;

  // PK_IN[0..7] @ 0x0010..0x002C (LSW->MSW) — write-only (read-as-zero)
  localparam int unsigned ADDR_PK_IN0     = 'h0010; // +4*i

  // Policy inputs
  localparam int unsigned ADDR_TZPC       = 'h0044;
  localparam int unsigned ADDR_DOMAIN     = 'h0048;
  localparam int unsigned ADDR_ACCESS_LV  = 'h004C;

  // Reason bitmap (latched mirror)
  localparam int unsigned ADDR_WHY_DENIED = 'h0050;

  // PK_ALLOW_SHADOW[0..7] @ 0x0060..0x007C — RW shadow of OTP public key
  localparam int unsigned ADDR_PK_ALLOW0  = 'h0060; // +4*i

  // Mirrors (read-only)
  localparam int unsigned ADDR_SOFTLOCK   = 'h0080;
  localparam int unsigned ADDR_LCS        = 'h0084;

  // ---------- STATUS bits ----------
  // packed into STATUS register as read-only flags
  localparam int ST_BUSY           = 0;
  localparam int ST_DONE           = 1;
  localparam int ST_PK_MATCH       = 2;
  localparam int ST_SIG_VALID      = 3; // BYPASS=1 for MVP
  localparam int ST_AUTH_PASS      = 4;
  // bits 5..7 reserved
  localparam int ST_DBGEN          = 8;

  // ---------- WHY_DENIED bits ----------
  // 1 when that reason blocks DBGEN
  localparam int WD_SOFTLOCK       = 0;
  localparam int WD_LCS            = 1;
  localparam int WD_TZPC           = 2;
  localparam int WD_PK_MISMATCH    = 3;
  localparam int WD_SIG_FAIL       = 4;
  localparam int WD_DOMAIN         = 5;
  localparam int WD_LEVEL          = 6;
  localparam int WD_TIMEOUT        = 7;

  // 보호 레지스터(필터 밖 주소 예시)
  localparam logic [15:0] ADDR_PROT       = 16'h0100;

  // 프리-인증 허용 윈도우(메일박스/정책 레지스터 범위)
  localparam logic [15:0] PRE_ALLOW_LOW   = 16'h0000;
  localparam logic [15:0] PRE_ALLOW_HIGH  = 16'h00FF; // 네 맵에 맞게 조정 가능
endpackage
