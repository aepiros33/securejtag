# Module Hierarchy & Data Path (Read example)

PC (Vivado Console)
    │   mrd 0x00000100
    ▼
JTAG Cable / Debug Port
    │   (JTAG)
    ▼
[Xilinx JTAG-to-AXI Master IP]   ← AXI4-Lite Master (Debug Core)
    │   ARADDR=0x00000100
    ▼
──────────────────────────────────────────────────────────────
arty_secure_jtag_axi_demo.sv   (Top @ FPGA)
──────────────────────────────────────────────────────────────
    │
    ├─ AXI-Lite Bus
    │     │
    │     └▶ axi_lite2apb_bridge.sv            (AXI→APB 변환)
    │               │   PADDR=0x00000100
    │               ▼
    │        apb_reg_bridge.sv                  (슬레이브 선택/다중화)
    │               │
    │               ├─ regbus_filter_prepost.sv   (Pre/Post 필터)
    │               │         │
    │               │         └▶ jtag_mailbox_regfile.sv (APB Slave: 레지스터/메일박스)
    │               │                   ├─ RESULT/WHY/ID/NONCE … (0x0000~0x00FF)
    │               │                   └─ MEM Window/MBX Data…  (0x0100~…)
    │               │
    │               ├─ access_policy.sv          (접근 정책/LCS/LEVEL 체크)
    │               ├─ auth_fsm_plain.sv         (인증 FSM: plain/stub)
    │               ├─ otp_ctrl.sv               (OTP/soft_lock/PK stub)
    │               └─ dp_wrapper_stub.sv        (디버그 경로 stub)
    │
    └─ (optional) 기타 AXI 슬레이브/DDR/BRAM 등

Return path:
Register/MBX → PRDATA → apb_reg_bridge → axi_lite2apb_bridge → AXI RDATA → JTAG-to-AXI → Vivado Console
