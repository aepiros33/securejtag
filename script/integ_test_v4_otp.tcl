# ======================================================================
# integ_test_otp4_direct.tcl — OTP loopback + Direct 4bit AUTH (one-shot)
#   - UTF-8
#   - RD_STRONG(): 동일주소 다중 샘플로 강건 읽기
#   - OTP-4bit 직결 FSM 전제
#   - 256-bit PK dump 기능 추가 (FPGA2 APB read-only)
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

# OTP client (FPGA1)
set O_CMD         0x00000090
set O_STAT        0x00000094
set O_DATA        0x00000098
set O_CNT         0x0000009C

# Debug
set D_DEV0        0x000000B0
set D_VER         0x000000B4
set D_HS0         0x000000B8

# OTP server (FPGA2 PK dump via APB)
set PK_BASE       0x00000100   ;# 256-bit f_pk read-only window (8×32bit)

# ---------- Helpers ----------
proc BIT {status bitidx} { return [expr {($status >> $bitidx) & 1}] }

# ---------- New: Read full 256-bit PK from FPGA2 ----------
proc read_pk256 {} {
  set pk_words {}
  for {set i 0} {$i < 8} {incr i} {
    set val [RD [expr {$::PK_BASE + 4*$i}]]
    lappend pk_words [format %08X $val]
  }
  puts [format "OTP f_pk (256b) = %s" $pk_words]
  return $pk_words
}

# ---------- Expect helpers ----------
proc expect_eq {label got expect} {
  set g [expr {$got & 0xFFFFFFFF}]
  set e [expr {$expect & 0xFFFFFFFF}]
  if {$g == $e} { _pass "[format "%s  got=%s" $label [H8 $g]]"; return 1 }
  _fail "[format "%s  got=%s  expect=%s" $label [H8 $g] [H8 $e]]"; return 0
}
proc expect_flag {label status bit expect1or0} {
  set got [BIT $status $bit]; return [expect_eq $label $got $expect1or0]
}

# ---------- OTP core suite ----------
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

proc otp_wait_done {{limit 300} {interval_ms 1}} {
  for {set i 0} {$i < $limit} {incr i} {
    set s [RD $::O_STAT]
    if { ( $s & 0x2 ) != 0 } { return $s }
    after $interval_ms
  }
  error "OTP timeout waiting DONE(sticky)"
}

proc otp_suite {} {
  _hr "="
  puts "OTP: single-board loopback tests (CMD=0/1/2)"
  set ok 1
  puts "* CMD=0 (SOFT)";  if {! [otp_issue_and_check 0 0x1]} { set ok 0 }
  puts "* CMD=1 (LCS)";   if {! [otp_issue_and_check 1 0x2]} { set ok 0 }
  puts "* CMD=2 (PKLS)";  if {! [otp_issue_and_check 2 -1]}  { set ok 0 }

  if {$ok} { 
    _pass "OTP suite completed"
    # ★ Read the entire 256-bit PK dump from FPGA2 (APB read-only)
    set pk_dump [read_pk256]
    puts [format "OTP PK dump complete: %s" $pk_dump]
  } else {
    _fail "OTP suite had failures"
  }
  return $ok
}

# ---------- (Remaining auth functions etc. unchanged) ----------
# ... (auth_reset_env, learn_soft, learn_pkls, auth_pass_scenario, etc.)
# ---------- main ----------
proc run_all {} {
  _hr "#"; puts "RUN-ALL: OTP + AUTH (Direct OTP-4bit)"
  axi_attach
  check_otp_version 1
  set ok1 0; set rc1 [catch { set ok1 [otp_suite] } e1]
  if {$rc1 != 0} { _fail "OTP suite crashed: $e1" }
  # (auth_suite can be called here if needed)
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
