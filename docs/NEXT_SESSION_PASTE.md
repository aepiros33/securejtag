# NEXT SESSION PASTE-BLOCK (copy below into a new ChatGPT session)

**Project**: securejtag (Arty A7-100)  
**Repo/Branch**: aepiros33/securejtag @ main  
**Vivado**: 2021.1  
**Top**: arty_secure_jtag_axi_demo  
**Key dirs**: PBL.srcs/{sources_1,constrs_1,sim_1}, script/

## What I need help with *today*
- [ ] (적어줘) 예: AXI-Lite → APB 브리지에서 주소 디코딩 점검
- [ ] (적어줘) 예: jtag_mailbox_regfile RESULT/WHY 비트 정의 확정
- [ ] (적어줘) 예: XDC 타이밍/핀 검증

## Key files/modules
- Top: `PBL.srcs/sources_1/**/arty_secure_jtag_axi_demo.sv`
- Bridge: `axi_lite2apb_bridge.sv`, `apb_reg_bridge.sv`
- Filter/Reg: `regbus_filter_prepost.sv`, `jtag_mailbox_regfile.sv`
- Policy/Auth: `access_policy.sv`, `auth_fsm_plain.sv`, `otp_ctrl.sv`
- Stub: `dp_wrapper_stub.sv`
- Constraints: `PBL.srcs/constrs_1/*.xdc`
- Vivado TCL: `script/proj.tcl`

## Board/clock/reset
- Device: `xc7a100tcsg324-1` (Arty A7-100)  
- clk = 100 MHz (보드 기본), reset_n = active-low (XDC 참고)

## Address map (draft)
- 0x0000 ~ 0x00FF: STATUS/ID/WHY/NONCE/RESULT (세부는 REGMAP.md 참고)
- 0x0100 ~ ...   : Mailbox/MEM window (세부는 REGMAP.md 참고)

## Open issues / decisions
- (적어줘) 예: RESULT[0]=auth_pass, RESULT[1]=soft_lock … 최종 확정 필요
- (적어줘) 예: NONCE/PUF 대체 로직 임시값 → 후속 치환 계획
- (적어줘) 예: Pre/Post filter 구간/조건 정리

## How to build (quick)
Vivado Tcl:  
