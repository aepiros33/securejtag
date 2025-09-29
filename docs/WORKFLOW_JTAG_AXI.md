# JTAG-to-AXI Master Workflow (Vivado Console)

## Pre-check
- Bitstream 다운로드 완료, Debug hub 연결 OK
- JTAG-to-AXI Master core 인식 확인

## Read example
mrd 0x00000000 # RESULT(예시)
mrd 0x00000004 # WHY
mrd 0x00000100 # MBX window 시작


## Write example
mwr 0x00000030 0x00000001 # CMD: auth/bypass 등 트리거(예시)
mwr 0x00000034 0x12345678 # ARG: 인자(예시)


## Notes
- 주소/오프셋은 REGMAP.md 실측값으로 업데이트
- pre/post filter 동작 확인 시: pre에서 차단 → WHY 코드 확인
- DEV/PROD LCS/LEVEL 전환 시나리오 기록 권장
