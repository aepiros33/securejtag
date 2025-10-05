encoding system utf-8


# ------- Global holder -------
set ::HW_AXI ""

# ------- Helpers -------
proc _to_hex32 {x} {
  if {[string match "0x*" $x]} { scan $x %x v; return [format 0x%08X $v] }
  return [format 0x%08X $x]
}
proc _hex_to_int {hex} { scan $hex %x v; return $v }
proc show32 {val} { puts [format 0x%08X $val] }
proc hr {} { puts "----------------------------------------" }

# ------- AXI attach (robust) -------
proc axi_attach {} {
  puts "\nAXI: attaching to JTAG-to-AXI..."
  open_hw_manager
  catch { disconnect_hw_server }
  connect_hw_server
  open_hw_target
  set devs [get_hw_devices]
  if {[llength $devs] == 0} { error "No hw device found" }
  set dev [lindex $devs 0]
  current_hw_device $dev
  refresh_hw_device $dev

  set axis [get_hw_axis]
  if {[llength $axis] == 0} { error "No HW AXI cores found" }
  set pick ""
  foreach a $axis {
    set name [get_property NAME $a]
    if {[string match -nocase *jtag* $name]} { set pick $a; break }
  }
  if {$pick eq ""} { set pick [lindex $axis 0] }

  set ::HW_AXI $pick
  puts "AXI: attached to: [get_property NAME $::HW_AXI]"
}

# ------- Guard -------
proc _ensure_axi {} {
  if {![info exists ::HW_AXI] || $::HW_AXI eq ""} { axi_attach }
}

# ------- AXI R/W -------
proc mrd {addr} {
  _ensure_axi
  set addr [_to_hex32 $addr]
  set name "rd_[clock clicks]"
  create_hw_axi_txn $name $::HW_AXI -type read -address $addr -len 1
  if {[catch { run_hw_axi $name } emsg]} {
    delete_hw_axi_txn $name
    error "mrd($addr) failed: $emsg"
  }
  set d_hex [lindex [get_property DATA [get_hw_axi_txn $name]] 0]
  delete_hw_axi_txn $name
  return [_hex_to_int $d_hex]
}
proc mwr {addr data} {
  _ensure_axi
  set addr [_to_hex32 $addr]
  set data [_to_hex32 $data]
  set name "wr_[clock clicks]"
  create_hw_axi_txn $name $::HW_AXI -type write -address $addr -len 1 -data $data
  if {[catch { run_hw_axi $name } emsg]} {
    delete_hw_axi_txn $name
    error "mwr($addr,$data) failed: $emsg"
  }
  delete_hw_axi_txn $name
}

# ------- Pretty expect -------
proc expect_eq {label got expect_hex} {
  set expect [_hex_to_int $expect_hex]
  set ok [expr {$got == $expect}]
  set ghex [format 0x%08X $got]
  set ehex [format 0x%08X $expect]
  puts "[format "%-24s" $label] [expr {$ok ? "PASS" : "FAIL"}]  got=$ghex  [expr {$ok ? "" : "expect=$ehex"}]"
  return $ok
}

# ------- Address map -------
set ADDR_CMD         0x00000000
set ADDR_STATUS      0x00000004
set ADDR_PK_IN0      0x00000010
set ADDR_TZPC        0x00000044
set ADDR_DOMAIN      0x00000048
set ADDR_ACCESS_LV   0x0000004C
set ADDR_WHY_DENIED  0x00000050
set ADDR_PK_ALLOW0   0x00000060
set ADDR_SOFTLOCK    0x00000080
set ADDR_LCS         0x00000084
set BRAM_BASE        0x00000100


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


encoding system utf-8

# ─── OTP 주소 ───
set ADDR_OTP_CMD    0x00000090
set ADDR_OTP_STATUS 0x00000094   ;# [1]=DONE(sticky), [0]=BUSY
set ADDR_OTP_DATA   0x00000098   ;# [3:0] = 응답 nibble (latched)
set ADDR_OTP_CNT    0x0000009C

# ─── 유틸 ───
proc otp_wait_done {{limit 200} {interval_ms 1}} {
  set ADDR_OTP_STATUS 0x00000094
  for {set i 0} {$i < $limit} {incr i} {
    set s [mrd $ADDR_OTP_STATUS]
    if {($s & 0x00000002) != 0} { return $s }  ;# DONE(sticky)
    after $interval_ms
  }
  error "OTP timeout waiting DONE"
}

proc otp_cmd_then_read {cmd expected_data expected_cnt} {
  set ADDR_OTP_CMD   0x00000090
  set ADDR_OTP_DATA  0x00000098
  set ADDR_OTP_CNT   0x0000009C

  mwr $ADDR_OTP_CMD $cmd
  otp_wait_done 200 1

  set d [mrd $ADDR_OTP_DATA]
  set c [mrd $ADDR_OTP_CNT]

  puts [format "CMD=%X  DATA=%X CNT=%X" $cmd $d $c]
  expect_eq [format "DATA for CMD %X" $cmd] $d $expected_data
  expect_eq [format "CNT  for CMD %X" $cmd] $c $expected_cnt

  return [list $d $c]
}

# ─── 실행 ───
proc run_all_tests {} {
  axi_attach

  # SOFT(=1), LCS(=2), PKLS(=3) — CMDW=2 기준
  # 기대값: SOFT=1, LCS=2, PKLS=(OTP_PK_ALLOW[3:0])
  #  → OTP_PK_ALLOW[3:0]는 하드코딩 값이 0이면 0 기대, 아니면 그 nibble로 수정
  set PKLS_EXPECT 0x0  ;# 필요하면 실제 fuse LSB에 맞게 조정

  puts "TEST: OTP single-board loopback"
  otp_cmd_then_read 0x0 0x1 0x1     ;# SOFT
  otp_cmd_then_read 0x1 0x2 0x2     ;# LCS
  otp_cmd_then_read 0x2 $PKLS_EXPECT 0x3  ;# PK LSB

  hr
  puts "DONE: OTP tests completed."
}

# auto-run
#run_all_tests
axi_attach 

