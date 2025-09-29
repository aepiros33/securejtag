# TODO / Decisions

## Design
- [ ] RESULT/WHY 비트 정의 최종 확정 (REGMAP.md 반영)
- [ ] LCS/LEVEL R/W 정책 (DEV만 허용? 시퀀스?)
- [ ] Pre/Post 필터 조건(주소 범위/권한) 명문화

## Impl
- [ ] axi_lite2apb_bridge 주소 디코딩/폭 검증
- [ ] jtag_mailbox_regfile 기본 리셋값/RO/WO 속성 반영
- [ ] auth_fsm_plain → 실제 검증 로직 전환 계획 수립

## Verification
- [ ] XSim TB: 정상/거부/바이패스 케이스
- [ ] Vivado Console: mrd/mwr 시나리오 스크립트 정리
- [ ] XDC 타이밍 검토(WNS/TNS), IO 표준/핀 확인
