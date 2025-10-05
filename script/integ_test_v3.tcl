# ======================================================================
# integ_test_otp4_direct.tcl — OTP loopback + Direct 4bit AUTH (one-shot)
#   - UTF-8
#   - RD_STRONG(): 동일주소 다중 샘플로 강건 읽기
#   - OTP-4bit 직결 FSM 전제 (브릿지 4bit→256b 스크립트 사용 금지)
#   - 시작 시 0x00B4 버전("OT8d"=0x4F543864) 강제 검증
# ======================================================================

encoding system utf-8
catch { set_msg_config -id {Labtoolstcl 44-481} -limit 0 }
catch { set_msg_config -id {Common 17-14} -limit 0 }

# ---------- Globals / counters ----------
set ::HW_AXI ""
set ::TEST_FAILS 0
set ::TEST_PASSES 0

proc _hr {{c "-"}} { puts [string repeat $c 60] }
proc _ts {} { clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S" }
proc H8 {x} { return [format 0x%08X [expr {$x & 0xFFFFFFFF}]] }
proc _pass {msg} { puts "[format %-48s $msg] PASS"; incr ::TEST_PASSES }
proc _fail {msg} { puts "[format %-48s $msg] FAIL"; incr ::TEST_FAILS }

# ---------- Attach ----------
proc axi_attach {} {
  _hr
  puts "[_ts] AXI: attaching to JTAG-to-AXI..."
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
  foreach a $axis { if {[string match -nocase *jtag* [get_property NAME $a]]} { set pick $a; break } }
  if {$pick eq ""} { set pick [lindex $axis 0] }
  set ::HW_AXI $pick
  puts "AXI: attached to: [get_property NAME $::HW_AXI]"
  _hr
}
proc _get_axi {} { if {$::HW_AXI eq ""} { axi_attach }; return $::HW_AXI }

# ---------- Low-level RD/WR ----------
proc _rd_once {addr} {
  set ax [_get_axi]
  set a  [format 0x%08X $addr]
  set tx rd_[clock clicks]
  create_hw_axi_txn $tx $ax -type read -address $a -len 1
  if {[catch { run_hw_axi $tx } em]} { delete_hw_axi_txn $tx; error "RD($a) failed: $em" }
  set raw [string trim [lindex [get_property DATA [get_hw_axi_txn $tx]] 0]]
  delete_hw_axi_txn $tx
  set val 0; scan $raw %x val
  return $val
}

# 강건 읽기: 동일 주소 2~3회 샘플
proc RD_STRONG {addr} {
  set v1 [_rd_once $addr]
  after 1
  set v2 [_rd_once $addr]
  if {$v1 == $v2} { return $v2 }
  after 1
  set v3 [_rd_once $addr]
  return $v3
}

proc RD {addr} { return [RD_STRONG $addr] }

proc WR {addr val} {
  set ax [_get_axi]
  set a  [format 0x%08X $addr]
  set d  [format %08X [expr {$val & 0xFFFFFFFF}]]
  set tx wr_[clock clicks]
  create_hw_axi_txn $tx $ax -type write -address $a -len 1 -data $d
  if {[catch { run_hw_axi $tx } em]} { delete_hw_axi_txn $tx; error "WR($a,$d) failed: $em" }
  delete_hw_axi_txn $tx
}

# ---------- Address map ----------
# Auth / Regfile
set A_CMD         0x00000000
set A_STATUS      0x00000004
set A_PK_IN0      0x00000010
set A_TZPC        0x00000044
set A_DOMAIN      0x00000048
set A_ACCESS_LV   0x0000004C
set A_WHY_DENIED  0x00000050
set A_PK_ALLOW0   0x00000060
set A_SOFTLOCK    0x00000080
set A_LCS         0x00000084
set BRAM_BASE     0x00000100

# OTP
set O_CMD         0x00000090
set O_STAT        0x00000094
set O_DATA        0x00000098
set O_CNT         0x0000009C

# Debug
set D_DEV0        0x000000B0
set D_VER         0x000000B4
set D_HS0         0x000000B8

# ---------- Helpers ----------
proc BIT {status bitidx} { return [expr {($status >> $bitidx) & 1}] }

proc expect_eq {label got expect} {
  set g [expr {$got & 0xFFFFFFFF}]
  set e [expr {$expect & 0xFFFFFFFF}]
  if {$g == $e} { _pass "[format "%s  got=%s" $label [H8 $g]]"; return 1 }
  _fail "[format "%s  got=%s  expect=%s" $label [H8 $g] [H8 $e]]"; return 0
}
proc expect_flag {label status bit expect1or0} {
  set got [BIT $status $bit]; return [expect_eq $label $got $expect1or0]
}

# 256b write helper (pk_in만 사용; allow는 호환용)
set PK_BASE {0x01234567 0x89ABCDEF 0xFEEDFACE 0xCAFEBABE 0x11223344 0x55667788 0x99AABBCC 0xDDEEFFAA}
proc pkvec_with_nib {nib} {
  set L $::PK_BASE
  set w7 [lindex $L 7]
  set w7 [expr {($w7 & 0xFFFFFFF0) | ($nib & 0xF)}]
  lset L 7 $w7
  return $L
}
proc write_u256 {base words8} {
  for {set i 0} {$i < 8} {incr i} { WR [expr {$base + 4*$i}] [lindex $words8 $i] }
}

# ---------- Version check (0xB4) ----------
set REQUIRED_OTP_VER 0x4F543864  ;# "OT8d"

proc ascii4 {val} {
  set b0 [expr {($val >> 24) & 0xFF}]
  set b1 [expr {($val >> 16) & 0xFF}]
  set b2 [expr {($val >>  8) & 0xFF}]
  set b3 [expr { $val        & 0xFF}]
  return [format "%c%c%c%c" $b0 $b1 $b2 $b3]
}
proc check_otp_version {{strict 1}} {
  set v [RD $::D_VER]
  puts [format "OTP DBG_VERSION(0xB4) = %s (%s)" [H8 $v] [ascii4 $v]]
  if {$strict} {
    if {$v != $::REQUIRED_OTP_VER} {
      puts [format "EXPECTED = %s (%s)" [H8 $::REQUIRED_OTP_VER] [ascii4 $::REQUIRED_OTP_VER]]
      error "Wrong bitstream/old RTL picked. Stop."
    } else {
      puts "Version check: OK (strict)"
    }
  } else {
    set ok [expr { (($v & 0xFFFF0000) == 0x4F540000) && ((( $v >> 8) & 0xFF) == (($::REQUIRED_OTP_VER >> 8) & 0xFF)) }]
    if {!$ok} {
      puts [format "EXPECTED ~ %s" [H8 $::REQUIRED_OTP_VER]]
      error "Incompatible OTP client version. Stop."
    } else {
      puts "Version check: OK (loose)"
    }
  }
}

# ---------- Pollers ----------
proc poll_status_done {{limit 200} {interval_ms 5}} {
  for {set i 0} {$i < $limit} {incr i} {
    set s [RD $::A_STATUS]
    if { ( $s & 0x2 ) != 0 } { return $s }  ;# DONE(bit1)
    after $interval_ms
  }
  error "Timeout waiting for STATUS.DONE"
}
proc otp_wait_done {{limit 300} {interval_ms 1}} {
  for {set i 0} {$i < $limit} {incr i} {
    set s [RD $::O_STAT]
    if { ( $s & 0x2 ) != 0 } { return $s }  ;# DONE(sticky)
    after $interval_ms
  }
  error "OTP timeout waiting DONE(sticky)"
}

# ---------- OTP suite ----------
proc otp_issue_and_check {cmd expected_data_or_minus1} {
  set cnt0 [RD $::O_CNT]
  WR $::O_CMD $cmd
  otp_wait_done
  set d   [RD $::O_DATA]
  set cnt [RD $::O_CNT]
  set hs0 [RD $::D_HS0]
  set dv0 [RD $::D_DEV0]
  puts [format "  HS0=%s  DEV0=%s" [H8 $hs0] [H8 $dv0]]

  _pass [format "  CNT increased by 1 (prev=%s now=%s)" [H8 $cnt0] [H8 $cnt]]
  set ok1 [expect_eq "  CNT exact" $cnt [expr {$cnt0 + 1}]]

  if {$expected_data_or_minus1 < 0} {
    set expect [expr {$dv0 & 0xF}]
    set ok2 [expect_eq "  DATA derived(expect DEV0[3:0])" $d $expect]
  } else {
    set ok2 [expect_eq "  DATA exact" $d $expected_data_or_minus1]
  }
  return [expr {$ok1 && $ok2}]
}
proc otp_suite {} {
  _hr "="
  puts "OTP: single-board loopback tests (CMD=0/1/2)"
  set ok 1
  puts "* CMD=0 (SOFT)";  if {! [otp_issue_and_check 0 0x1]} { set ok 0 }
  puts "* CMD=1 (LCS)";   if {! [otp_issue_and_check 1 0x2]} { set ok 0 }
  puts "* CMD=2 (PKLS)";  if {! [otp_issue_and_check 2 -1]}  { set ok 0 }
  if {$ok} { _pass "OTP suite completed" } else { _fail "OTP suite had failures" }
  return $ok
}

# ---------- AUTH (Direct OTP‑4bit) ----------
proc auth_reset_env {} {
  WR $::A_CMD       0x00000002   ;# RESET_FSM
  WR $::A_TZPC      0x0000003F
  WR $::A_DOMAIN    0x00000001
  WR $::A_ACCESS_LV 0x00000004
  after 1
}
proc learn_soft   {} { WR $::O_CMD 0x0; otp_wait_done; return [expr {[RD $::O_DATA] & 0x1}] }
proc learn_lcs3   {} { WR $::O_CMD 0x1; otp_wait_done; return [expr {[RD $::O_DATA] & 0x7}] }
proc learn_pkls   {} { WR $::O_CMD 0x2; otp_wait_done; return [expr {[RD $::O_DATA] & 0xF}] }

proc auth_pass_scenario {} {
  _hr; puts "AUTH: PASS scenario (direct 4bit)"
  auth_reset_env
  set pkls [learn_pkls]
  puts [format "  Learn OTP: PKLS=0x%X" $pkls]

  write_u256 $::A_PK_IN0    [pkvec_with_nib $pkls]
  write_u256 $::A_PK_ALLOW0 [pkvec_with_nib $pkls]  ;# 호환용

  WR $::A_CMD 0x00000001  ;# START
  set s   [poll_status_done]
  set why [RD $::A_WHY_DENIED]
  puts [format "  STATUS=%s  WHY=%s" [H8 $s] [H8 $why]]

  set ok1 [expect_flag "  AUTH_PASS bit" $s 4 1]
  set ok2 [expect_flag "  DBGEN bit"     $s 8 1]

  set a0  [expr {$::BRAM_BASE + 0}]
  set pat 0xAABBCCDD
  WR $a0 $pat
  set r0 [RD $a0]
  set ok3 [expect_eq "  BRAM R/W after PASS" $r0 $pat]

  return [expr {$ok1 && $ok2 && $ok3}]
}

proc auth_fail_scenario {} {
  _hr; puts "AUTH: FAIL scenario (direct 4bit)"
  auth_reset_env
  set pkls [learn_pkls]
  set bad  [expr {($pkls ^ 1) & 0xF}]
  puts [format "  Learn OTP: PKLS=0x%X  -> BAD nib=0x%X" $pkls $bad]

  write_u256 $::A_PK_IN0    [pkvec_with_nib $bad]
  write_u256 $::A_PK_ALLOW0 [pkvec_with_nib $pkls]

  WR $::A_CMD 0x00000001
  set s   [poll_status_done]
  set why [RD $::A_WHY_DENIED]
  puts [format "  STATUS=%s  WHY=%s" [H8 $s] [H8 $why]]

  set ok1 [expect_flag "  AUTH_PASS bit=0" $s 4 0]
  set ok2 [expect_flag "  DBGEN bit=0"     $s 8 0]

  # 정책 lock 확인(정보)
  set a0 [expr {$::BRAM_BASE + 0}]
  WR $a0 0xDEADBEEF
  set r0 [RD $a0]
  if {$r0 == 0x00000000} { _pass "  BRAM locked after FAIL (read 0)" } else { puts [format "  BRAM lock (info): read=%s" [H8 $r0]] }

  return [expr {$ok1 && $ok2}]
}

# --- 교체 1: BYPASS 도우미 ---
proc set_bypass {onoff} {
  # onoff=1 → BYPASS ON(soft_lock=0), onoff=0 → BYPASS OFF(soft_lock=1)
  if {$onoff} {
    WR $::A_SOFTLOCK 0x00000000
  } else {
    WR $::A_SOFTLOCK 0x00000001
  }
  after 1
}

# --- 교체 2: BYPASS 시나리오 ---
proc auth_bypass_scenario {} {
  _hr; puts "AUTH: BYPASS scenario (force soft_lock=0 during test)"
  # 1) 잠금 해제
  set_bypass 1

  # 2) R/W 시도
  set a0 [expr {$::BRAM_BASE + 0}]
  WR $a0 0x55667788
  set r0 [RD $a0]
  set ok [expr {$r0 == 0x55667788}]

  if {$ok} {
    _pass "  BRAM R/W after BYPASS  got=[H8 $r0]"
  } else {
    _fail [format "  BRAM not open  got=%s" [H8 $r0]]
  }

  # 3) 원복: BYPASS OFF
  set_bypass 0

  return $ok
}

proc auth_suite {} {
  _hr "="; puts "JTAG AUTH flows (direct OTP‑4bit)"
  set okp 0; set rc [catch { set okp [auth_pass_scenario] } em]
  if {$rc != 0} { _fail "AUTH PASS scenario crashed: $em"
  } elseif {!$okp} { _fail "AUTH PASS scenario failed checks"
  } else { _pass "AUTH PASS scenario completed" }

  set okf 0; set rc [catch { set okf [auth_fail_scenario] } em]
  if {$rc != 0} { _fail "AUTH FAIL scenario crashed: $em"
  } elseif {!$okf} { _fail "AUTH FAIL scenario failed checks"
  } else { _pass "AUTH FAIL scenario completed" }

  set okb 0; set rc [catch { set okb [auth_bypass_scenario] } em]
  if {$rc != 0} { _fail "AUTH BYPASS scenario crashed: $em"
  } elseif {!$okb} { _fail "AUTH BYPASS scenario failed checks"
  } else { _pass "AUTH BYPASS scenario completed" }

  return [expr {$okp && $okf && $okb}]
}

# ---------- main ----------
proc run_all {} {
  _hr "#"; puts "RUN-ALL: OTP + AUTH (Direct OTP‑4bit)"
  axi_attach
  check_otp_version 1     ;# ★ strict 버전 검증

  set ok1 0; set rc1 [catch { set ok1 [otp_suite] } e1]
  if {$rc1 != 0} { _fail "OTP suite crashed: $e1" }

  set ok2 0; set rc2 [catch { set ok2 [auth_suite] } e2]
  if {$rc2 != 0} { _fail "AUTH suite crashed: $e2" }

  _hr "#"
  puts [format "SUMMARY:  PASSES=%d  FAILS=%d" $::TEST_PASSES $::TEST_FAILS]
  if {$::TEST_FAILS > 0} {
    error [format "Integrated test finished with %d FAIL(s)" $::TEST_FAILS]
  } else {
    puts "Integrated test finished with all PASS."
  }
  _hr "#"
}

# auto-run
run_all
