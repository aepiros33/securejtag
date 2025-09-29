# Register Map (Draft)

Base: (APB base TBD)  
> 실제 주소/오프셋은 프로젝트와 일치하도록 업데이트

## 0x0000 ~ 0x00FF : Status / ID / Control
| Offset | Name     | Access | Bits                     | Reset | Description                          |
|-------:|----------|:------:|--------------------------|:-----:|--------------------------------------|
| 0x0000 | RESULT   |  RO    | [0]=auth_pass, [1]=soft_lock, [2]=bypass_en (예시) | 0x0 | 인증/락/바이패스 상태 비트 |
| 0x0004 | WHY      |  RO    | code (reason of deny)    | 0x0   | 접근 거부 원인 코드                  |
| 0x0008 | CHIP_ID  |  RO    | 32b                      | (TBD) | 칩/빌드 식별                         |
| 0x000C | LCS      | R/W?   | [2:0]                    | (TBD) | 라이프사이클 상태 (DEV/PROD…)        |
| 0x0010 | LEVEL    | R/W?   | [n:0]                    | (TBD) | 접근 레벨 / 정책                     |
| 0x0020 | NONCE    |  RO    | 32b (or 64b)             | (TBD) | 챌린지용 논스/PUF 대체값             |
| 0x0030 | CMD      |  WO    | cmd code                 | -     | 명령 (인증/바이패스 등 트리거)       |
| 0x0034 | ARG      |  WO    | arg                      | -     | 명령 인자                             |

> Access는 실제 구현에 맞춰 RO/WO/RW로 조정. LCS/LEVEL R/W는 DEV 모드에서만 허용 등 정책이 있으면 주석 추가.

## 0x0100 ~ ... : Mailbox / MEM Window
| Offset | Name        | Access | Width | Description                  |
|-------:|-------------|:------:|------:|------------------------------|
| 0x0100 | MBX_DATA0   |  R/W   | 32b   | 메일박스 데이터(저수준 I/O)  |
| 0x0104 | MBX_DATA1   |  R/W   | 32b   | …                            |
| ...    | ...         |  ...   | ...   |                              |

### WHY (deny code) 예시 테이블
| Code | Meaning                      |
|----:|-------------------------------|
| 0x00 | OK                           |
| 0x02 | LCS mismatch                 |
| 0x04 | Access level insufficient    |
| 0x08 | Policy blocked (pre-filter)  |
| 0x10 | Signature/PK invalid (stub)  |

> 위 코드는 실제 구현에 맞춰 갱신.
