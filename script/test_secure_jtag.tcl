# ============================
# test_secure_jtag_fixed.tcl
# ============================

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

# ------- Tests -------
proc test_read_basics {} {
  global ADDR_STATUS ADDR_SOFTLOCK ADDR_LCS
  hr
  puts "TEST: Basic STATUS/SFR reads"
  set st  [mrd $ADDR_STATUS]
  set sl  [mrd $ADDR_SOFTLOCK]
  set lcs [mrd $ADDR_LCS]
  puts [format "STATUS   = 0x%08X" $st]
  puts [format "SOFTLOCK = 0x%08X" $sl]
  puts [format "LCS      = 0x%08X" $lcs]
}

proc test_axi_writeback {} {
  global ADDR_TZPC
  hr
  puts "TEST: AXI write-back (TZPC)"
  set val 0xA5A5A5A5
  mwr $ADDR_TZPC $val
  set rd [mrd $ADDR_TZPC]
  expect_eq "TZPC write-back" $rd $val
}

proc test_softlock_toggle {} {
  global ADDR_SOFTLOCK
  hr
  puts "TEST: SOFTLOCK toggle"
  set sl0 [mrd $ADDR_SOFTLOCK]
  puts [format "SOFTLOCK init = 0x%08X" $sl0]
  mwr $ADDR_SOFTLOCK 0x00000000
  set sl1 [mrd $ADDR_SOFTLOCK]
  mwr $ADDR_SOFTLOCK 0x00000001
  set sl2 [mrd $ADDR_SOFTLOCK]
  expect_eq "SOFTLOCK -> 0" $sl1 0x00000000
  expect_eq "SOFTLOCK -> 1" $sl2 0x00000001
}

proc test_bram_rw {} {
  global BRAM_BASE ADDR_SOFTLOCK
  hr
  puts "TEST: BRAM R/W with lock mask"
  # unlock
  mwr $ADDR_SOFTLOCK 0x00000000
  set a0 [expr {$BRAM_BASE + 0}]
  set a4 [expr {$BRAM_BASE + 4}]
  mwr $a0 0x11223344
  set r0 [mrd $a0]
  puts [format "UNLOCK read @0x%08X = 0x%08X" $a0 $r0]
  set r4 [mrd $a4]
  puts [format "UNLOCK read @0x%08X = 0x%08X" $a4 $r4]
  # lock again
  mwr $ADDR_SOFTLOCK 0x00000001
  set rl0 [mrd $a0]
  set rl4 [mrd $a4]
  expect_eq "LOCK read @+0" $rl0 0x00000000
  expect_eq "LOCK read @+4" $rl4 0x00000000
}

proc test_pk_allow_shadow {} {
  global ADDR_PK_ALLOW0 ADDR_LCS
  hr
  puts "TEST: PK_ALLOW[0] RW in DEV"
  set lcs [mrd $ADDR_LCS]
  puts [format "LCS=0x%08X (DEV=0x2이면 쓰기 허용)" $lcs]
  set val 0xDEADBEEF
  mwr $ADDR_PK_ALLOW0 $val
  set rd [mrd $ADDR_PK_ALLOW0]
  expect_eq "PK_ALLOW[0] write-back" $rd $val
}

# ------- Runner -------
proc run_all_tests {} {
  axi_attach
  test_read_basics
  test_axi_writeback
  test_softlock_toggle
  test_bram_rw
  test_pk_allow_shadow
  hr
  puts "DONE: tests completed."
}

# auto-run
run_all_tests
