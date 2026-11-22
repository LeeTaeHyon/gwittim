# LLM 게시판 목록 읽기 시험

## 목적
- 전용 어댑터 없이 LLM이 학교 게시판 목록을 읽을 수 있는지 측정
- 최종보고서 '확장 가능성' 항목에 넣을 숫자 확보 (새 학교 추가 시 어댑터 없이 어디까지 되는가)

## 왜 명지 게시판만
- 이용 범위가 정리된 대상 (source-review.md)
- 새 학교 사이트에 요청하지 않음
- 외부 LLM 전달은 source-review.md상 팀장 확인 사항. api·cli 실행 전 확인 필요 (cli도 내용은 Anthropic으로 전달됨)

## 방법
- 정답 = 기존 어댑터 파서(`parse_list`) 결과: 제목, 게시일, 상세 식별자, 고정 공지 여부
- 예측 = 어댑터 없이 페이지를 LLM에 전달한 결과 (사이트 구조 힌트 없음)
- 입력 전처리는 일반 처리만: script/style/svg/주석 제거, 공백 정리, 20만 자 상한(초과 시 뒤를 자르고 결과에 표시)
- 구조화 출력: `items[]` = title, posted_date, detail_url, is_pinned_notice
- 제공자: fake(흐름 확인) / cli(로컬 `claude -p`, 구독) / api(`ANTHROPIC_API_KEY`, claude-haiku-5-5) / opencode(팀장 OpenCode Go 구독, DeepSeek V4.1 Flash, 생각 끔, 도구 전부 끈 설정으로 빈 임시 폴더에서 실행)

## 지표
- 매칭: 상세 식별자(BD 번호) 우선, 없으면 정규화 제목(공백·기호 무시)
- 재현율 = 매칭된 정답 / 정답 전체
- 정밀도 = 매칭된 예측 / 예측 전체 (메뉴·광고 링크를 항목으로 낸 것 = 오탐)
- 제목 일치율 = 정규화 후 완전 일치 / 매칭
- 게시일 일치율 = YYYY-MM-DD 정규화 후 일치 / 정답에 날짜 있는 매칭
- 링크 일치율 = 식별자 일치 / 매칭
- 고정 공지 일치 = 정답에 정보가 있는 매칭만
- 비용 = 토큰 기준 원화 추정, 1,400원/$
  - api: Haiku 입력 $0.10·출력 $0.50 /MTok
  - opencode: DeepSeek 공식 단가로 환산(할인 $0.15·$0.60, 피크 $0.30·$1.20). 실제 청구는 정액 구독. OpenCode 자체 지시문 몫(짧은 기준 호출 2번 중 작은 값)을 페이지마다 뺌

## 실행 순서
1. `uv run python tools/llm_board_read.py fetch --pages 1` (활성 4개 게시판, 3초 간격, 저장분은 재요청 안 함)
2. `uv run python tools/llm_board_read.py run --provider cli --limit-pages 2` (맛보기)
3. OpenCode 구독으로 전체: `PYTHONPATH=.venv/Lib/site-packages C:/AI/Anime-Llasa/Python312/python.exe tools/llm_board_read.py run --provider opencode`
   (`uv run` 아래에서는 opencode가 로그 파일을 못 열어 실패)
4. Anthropic 키가 생기면 `ANTHROPIC_API_KEY=... uv run python tools/llm_board_read.py run --provider api`
5. 결과: `data/local/llm_board_read/runs/<provider>_<시각>/summary.json` (git 제외)

## 결과 (2026-11-22, opencode, 명지 활성 게시판 4개 × 목록 1페이지)

| 게시판 | 정답 | 예측 | 재현율 | 정밀도 | 제목 | 게시일 | 링크 | 고정 공지 |
|---|---|---|---|---|---|---|---|---|
| 채용 | 12 | 12 | 100% | 100% | 100% | 100% | 100% | 100% |
| 공지 | 24 | 24 | 100% | 100% | 100% | 100% | 100% | 100% |
| 장학 | 18 | 18 | 100% | 100% | 100% | 100% | 100% | 100% |
| 근로 | 10 | 10 | 100% | 100% | 100% | 100% | 100% | 100% |
| **전체** | **64** | **64** | **100%** | **100%** | **100%** | **100%** | **100%** | **100%** |

- 토큰: 입력 95,512(OpenCode 몫 뺀 값) / 출력 9,332
- 환산 비용: 27.9원(페이지당 약 7원), 피크 단가면 55.8원(페이지당 약 14원)
- 시간: 합계 77.9초, 페이지당 19.5초(12~26초)
- 잘린 페이지 없음, 오류 0
- 앞선 cli(Haiku) 맛보기 2페이지도 100%

## 결과를 넣을 곳
- docs/stage2-results.md 에 한 줄 (제공자·페이지 수·재현율·정밀도·비용)
- 최종보고서 '확장 가능성' 절

## 한계
- 명지 한 학교, 목록 페이지만 (상세 본문은 보지 않음)
- 정답도 기존 파서 결과라 파서 오류는 그대로 정답이 됨
- cli는 토큰 수·비용을 알 수 없음. opencode 비용은 환산값(OpenCode 몫을 기준 호출로 빼서 약간의 오차)
- 페이지 수가 적어 비율의 신뢰구간이 넓음
