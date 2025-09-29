package secure_jtag_pkg;

  // =====(옵션) 공개키 입력 워드 수(32b 단위)=====
  localparam int unsigned PK_WORDS = 8; // PK_IN0..7

  // ---------- Address Map (byte offsets) ----------
  localparam int unsigned ADDR_CMD        = 'h0000;
  localparam int unsigned ADDR_STATUS     = 'h0004;

  // PK_IN[0..7] @ 0x0010..0x002C (LSW->MSW)
  localparam int unsigned ADDR_PK_IN0     = 'h0010; // +4*i, i=0..PK_WORDS-1

  // Policy inputs / control
  localparam int unsigned ADDR_TZPC       = 'h0044;
  localparam int unsigned ADDR_DOMAIN     = 'h0048;
  localparam int unsigned ADDR_ACCESS_LV  = 'h004C;

  // Reason bitmap (latched mirror)
  localparam int unsigned ADDR_WHY_DENIED = 'h0050;

  // ★ 추가: BYPASS enable (DEV에서만 유효) — 반드시 reset=0
  localparam int unsigned ADDR_BYPASS_EN  = 'h0058;

  // PK_ALLOW_SHADOW[0..7] @ 0x0060..0x007C — RW shadow of OTP public key
  localparam int unsigned ADDR_PK_ALLOW0  = 'h0060; // +4*i

  // Mirrors (read-only)
  localparam int unsigned ADDR_SOFTLOCK   = 'h0080;
  localparam int unsigned ADDR_LCS        = 'h0084;

  // ---------- STATUS bits (기존 정의 유지) ----------
  // 패키지의 ST_*를 그대로 쓰고 싶으면 regfile STATUS 조립 시 이 인덱스 사용
  localparam int ST_BUSY           = 0;
  localparam int ST_DONE           = 1;
  localparam int ST_PK_MATCH       = 2;
  localparam int ST_SIG_VALID      = 3; // MVP에선 BYPASS 의미로 사용 가능
  localparam int ST_AUTH_PASS      = 4;
  // bits 5..7 reserved
  localparam int ST_DBGEN          = 8;

  // ---------- WHY_DENIED bits (기존 정의 유지) ----------
  localparam int WD_SOFTLOCK       = 0;
  localparam int WD_LCS            = 1;
  localparam int WD_TZPC           = 2;
  localparam int WD_PK_MISMATCH    = 3;
  localparam int WD_SIG_FAIL       = 4;
  localparam int WD_DOMAIN         = 5;
  localparam int WD_LEVEL          = 6;
  localparam int WD_TIMEOUT        = 7;

  // ---------- Lifecycle State (★ 보강: enum) ----------
  typedef enum logic [2:0] {
    LCS_RAW   = 3'd0,
    LCS_TEST  = 3'd1,
    LCS_DEV   = 3'd2,   // DEV=2: BYPASS 허용 대상
    LCS_PROD  = 3'd3,
    LCS_RMA   = 3'd4
  } lcs_e;

  // ---------- Address ranges ----------
  // 메모리(차단 대상) 경계 — byte 주소 기준
  localparam logic [15:0] MEM_BASE_ADDR  = 16'h0100;

  // (기존 필드 유지) 보호 레지스터(필터 밖 주소 예시)
  // MEM_BASE_ADDR와 동일 개념이므로 둘 중 하나만 써도 됨
  localparam logic [15:0] ADDR_PROT      = 16'h0100;

  // 프리-인증 허용 윈도우(메일박스/정책 레지스터)
  localparam logic [15:0] PRE_ALLOW_LOW  = 16'h0000;
  localparam logic [15:0] PRE_ALLOW_HIGH = 16'h00FF;

endpackage
