encoding system utf-8

# ===== 추가 상수/유틸 =====
# (이미 있으면 중복 선언 생략 가능)
set CMD_START        0x00000001
set CMD_RESET_FSM    0x00000002
set CMD_DEBUG_DONE   0x00000004

set ST_BUSY          0x00000001
set ST_DONE          0x00000002
set ST_PK_MATCH      0x00000004
set ST_SIG_VALID     0x00000008
set ST_AUTH_PASS     0x00000010
set ST_DBGEN         0x00000100

set WD_SOFTLOCK      0x00000001
set WD_LCS           0x00000002
set WD_TZPC          0x00000004
set WD_PK_MISMATCH   0x00000008
set WD_SIG_FAIL      0x00000010
set WD_DOMAIN        0x00000020
set WD_LEVEL         0x00000040
set WD_TIMEOUT       0x00000080

# 256b 테스트 벡터
set PK_GOOD {0x01234567 0x89ABCDEF 0xFEEDFACE 0xCAFEBABE 0x11223344 0x55667788 0x99AABBCC 0xDDEEFF00}
set PK_BAD  {0xAAAAAAAA 0xBBBBBBBB 0xCCCCCCCC 0xDDDDDDDD 0xEEEEEEEE 0xFFFFFFFF 0x11111111 0x22222222}

# 256b 쓰기
proc write_u256 {base words8} {
  for {set i 0} {$i < 8} {incr i} {
    mwr [expr {$base + 4*$i}] [lindex $words8 $i]
  }
}

# DONE 폴링 (STATUS.DONE 올라올 때까지)
proc poll_done {{limit 200} {interval_ms 10}} {
  global ADDR_STATUS ST_DONE
  for {set i 0} {$i < $limit} {incr i} {
    set s [mrd $ADDR_STATUS]
    if {($s & $ST_DONE) != 0} { return $s }
    after $interval_ms
  }
  error "Timeout waiting for DONE"
}

# 상태 비트 체크 헬퍼
proc _flag {s mask} { expr {($s & $mask) != 0} }

# ===== 인증 성공 시나리오 =====
proc test_auth_pass_scenario {} {
  global ADDR_CMD ADDR_STATUS ADDR_WHY_DENIED
  global ADDR_TZPC ADDR_DOMAIN ADDR_ACCESS_LV
  global ADDR_PK_ALLOW0 ADDR_PK_IN0 BRAM_BASE
  global ST_AUTH_PASS ST_DBGEN WD_PK_MISMATCH PK_GOOD

  hr
  puts "TEST: AUTH PASS → 0x100 R/W open"

  # 정책/환경 리셋
  mwr $ADDR_CMD       0x00000002   ;# RESET_FSM
  mwr $ADDR_TZPC      0x0000003F
  mwr $ADDR_DOMAIN    0x00000001
  mwr $ADDR_ACCESS_LV 0x00000004

  # PK 주입 (ALLOW = IN = GOOD)
  write_u256 $ADDR_PK_ALLOW0 $PK_GOOD
  write_u256 $ADDR_PK_IN0    $PK_GOOD

  # START → DONE 대기
  mwr $ADDR_CMD 0x00000001
  set s [poll_done]
  set why [mrd $ADDR_WHY_DENIED]



# 교체(정상 동작)
puts [format "STATUS=0x%08X  AUTH_PASS=%d  DBGEN=%d" \
      $s [expr {($s & $ST_AUTH_PASS)!=0}] [expr {($s & $ST_DBGEN)!=0}]]

# WHY 출력도 이렇게
puts [format "WHY=0x%08X" [mrd $ADDR_WHY_DENIED]]


  # 기대: AUTH_PASS=1, DBGEN=1, WHY=0
  expect_eq "AUTH_PASS bit" [expr {$s & $ST_AUTH_PASS}] $ST_AUTH_PASS
  expect_eq "DBGEN bit"     [expr {$s & $ST_DBGEN}]     $ST_DBGEN
  expect_eq "WHY is zero"   $why 0x00000000

  # 0x100 R/W 열렸는지 확인
  set a0 [expr {$BRAM_BASE + 0}]
  set pat 0xAABBCCDD
  mwr $a0 $pat
  set r0 [mrd $a0]
  expect_eq "R/W @0x100 after AUTH_PASS" $r0 $pat
}

# ===== 인증 실패 시나리오 =====
proc test_auth_fail_scenario {} {
  global ADDR_CMD ADDR_STATUS ADDR_WHY_DENIED
  global ADDR_TZPC ADDR_DOMAIN ADDR_ACCESS_LV
  global ADDR_PK_IN0 BRAM_BASE
  global ST_AUTH_PASS ST_DBGEN WD_PK_MISMATCH PK_BAD

  hr
  puts "TEST: AUTH FAIL (PK mismatch) → 0x100 locked"

  # 정책/환경 리셋 (ALLOW는 이전 값 유지해도 무방)
  mwr $ADDR_CMD       0x00000002   ;# RESET_FSM
  mwr $ADDR_TZPC      0x0000003F
  mwr $ADDR_DOMAIN    0x00000001
  mwr $ADDR_ACCESS_LV 0x00000004

  # PK_IN만 BAD로
  write_u256 $ADDR_PK_IN0 $PK_BAD

  # START → DONE
  mwr $ADDR_CMD 0x00000001
  set s [poll_done]
  set why [mrd $ADDR_WHY_DENIED]

# 교체(정상 동작)
puts [format "STATUS=0x%08X  AUTH_PASS=%d  DBGEN=%d" \
      $s [expr {($s & $ST_AUTH_PASS)!=0}] [expr {($s & $ST_DBGEN)!=0}]]

# 기존(문제 가능)
# puts [format "STATUS=%s WHY=%s PK_MISMATCH=%d" [format 0x%08X $s] [format 0x%08X $why] ... ]

# 교체(정상 동작)
puts [format "STATUS=0x%08X  WHY=0x%08X  PK_MISMATCH=%d" \
      $s $why [expr {($why & $WD_PK_MISMATCH)!=0}]]


  # 기대: AUTH_PASS=0, DBGEN=0, WHY는 PK_MISMATCH 세트
  expect_eq "AUTH_PASS bit (should be 0)" [expr {$s & $ST_AUTH_PASS}] 0x00000000
  expect_eq "DBGEN bit   (should be 0)"   [expr {$s & $ST_DBGEN}]     0x00000000
  # WHY는 단정까진 말고 정보 출력만—환경에 따라 다른 비트 추가될 수 있어서

  # 0x100이 여전히 잠겨 있는지 확인 (READ=0, WRITE drop)
  set a0 [expr {$BRAM_BASE + 0}]
  mwr $a0 0xDEADBEEF
  set r0 [mrd $a0]
  expect_eq "LOCKED read @0x100 after AUTH_FAIL" $r0 0x00000000
}

# ===== (선택) BYPASS 시나리오 =====
proc test_bypass_scenario {} {
  global ADDR_SOFTLOCK BRAM_BASE
  hr
  puts "TEST: BYPASS (DEV) → 0x100 open"
  # BYPASS = soft_lock=0 (DEV에서만 의미 있음)
  mwr $ADDR_SOFTLOCK 0x00000000
  set a0 [expr {$BRAM_BASE + 0}]
  mwr $a0 0x55667788
  set r0 [mrd $a0]
  expect_eq "R/W @0x100 after BYPASS" $r0 0x55667788
}


proc run_all_tests {} {
  axi_attach

  # 0) 기본 SFR 동작
  test_read_basics
  test_axi_writeback
  test_softlock_toggle
  test_bram_rw
  test_pk_allow_shadow

  # 1) AUTH PASS → 0x100 open
  test_auth_pass_scenario

  # 2) AUTH FAIL → 0x100 locked
  test_auth_fail_scenario

  # 3) (선택) BYPASS (DEV) → 0x100 open
  #test_bypass_scenario

  hr
  puts "DONE: tests completed."
}


# auto-run
run_all_tests
