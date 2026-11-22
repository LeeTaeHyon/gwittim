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
- 제공자: fake(흐름 확인) / cli(로컬 `claude -p`, 구독) / api(`ANTHROPIC_API_KEY`, claude-haiku-5-5)

## 지표
- 매칭: 상세 식별자(BD 번호) 우선, 없으면 정규화 제목(공백·기호 무시)
- 재현율 = 매칭된 정답 / 정답 전체
- 정밀도 = 매칭된 예측 / 예측 전체 (메뉴·광고 링크를 항목으로 낸 것 = 오탐)
- 제목 일치율 = 정규화 후 완전 일치 / 매칭
- 게시일 일치율 = YYYY-MM-DD 정규화 후 일치 / 정답에 날짜 있는 매칭
- 링크 일치율 = 식별자 일치 / 매칭
- 고정 공지 일치 = 정답에 정보가 있는 매칭만
- 비용 = 토큰(api만) 기준 원화 추정. 입력 $0.10·출력 $0.50 /MTok, 1,400원/$ (llm.py와 동일)

## 실행 순서
1. `uv run python tools/llm_board_read.py fetch --pages 1` (활성 4개 게시판, 3초 간격, 저장분은 재요청 안 함)
2. `uv run python tools/llm_board_read.py run --provider cli --limit-pages 2` (맛보기)
3. 키가 생기면 `ANTHROPIC_API_KEY=... uv run python tools/llm_board_read.py run --provider api`
4. 결과: `data/local/llm_board_read/runs/<provider>_<시각>/summary.json` (git 제외)

## 결과를 넣을 곳
- docs/stage2-results.md 에 한 줄 (제공자·페이지 수·재현율·정밀도·비용)
- 최종보고서 '확장 가능성' 절

## 한계
- 명지 한 학교, 목록 페이지만 (상세 본문은 보지 않음)
- 정답도 기존 파서 결과라 파서 오류는 그대로 정답이 됨
- cli는 토큰 수·비용을 알 수 없음 (비용은 api 실행 때만 나옴)
- 페이지 수가 적어 비율의 신뢰구간이 넓음
