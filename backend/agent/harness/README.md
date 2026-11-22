# 상세 분석 지침 (하네스)

맞춤 에이전트 상세 분석이 LLM에 주는 지시문을 코드와 따로 둔 곳이다.

| 파일 | 내용 |
|---|---|
| `detail_analysis.md` | 지시문 본문. 그대로 LLM의 system 메시지가 된다(이 README는 보내지 않음) |
| `VERSION` | 지침 버전. 한 줄 |
| `external_search.md` | 외부 공고 찾기(웹 검색) 지시문(D-047). 결과 검증은 코드(`backend/agent/external.py`)가 함 |
| `EXTERNAL_VERSION` | 외부 공고 찾기 지침 버전. 로그 `external search done harness=…` |

## 고치는 순서

1. `detail_analysis.md`를 고친다
2. `VERSION`을 올린다(예: `detail-2026-11-23.1` → `detail-2026-11-23.2`, 날짜가 바뀌면 날짜도). **안 올리면 예전 저장본이 계속 나온다**
3. 시험: `uv run python tools/harness_check.py --compare <고치기 전 파일>` → `data/local/harness_check/`의 결과에서 리포트와 '위반'을 본다
4. `uv run pytest -q backend/agent` 통과 확인 → PR → 병합 → 서버 배포([docs/deploy-runbook.md](../../../docs/deploy-runbook.md))

## 지침을 고쳐도 꺼지지 않는 것 (코드가 강제)

- 리포트 4칸(`fit`, `eligibility`, `todo`, `skills`)과 JSON 형식: 서버가 검사하고, 빠지면 실패·크레딧 환불(`backend/agent/llm.py`)
- 지원 자격 판정: 서버 규칙(`backend/recommendation`)이 내리고 입력으로 준다. 지침은 그 판정을 설명할 뿐
- 영어 코드·내부 칸 이름: 받은 리포트에서 한국어로 치환(`prompt.scrub_codes`)
- 한 문단으로 온 칸: 문장 끝에서 줄로 나눔(`prompt.split_long_lines`)
- 역량·할 일 근거 맞추기(`prompt.ground_report`)
  - `skills`: '원문에서 확인할 조건' 원문과 두 글자 묶음이 절반 이상 겹치는 줄만 남김. '(우대)'는 원문 구분(우대 사항)으로 다시 붙임. 남는 줄이 없으면 '확인하기 어렵습니다' 문장
  - `todo`: 마감이 지났으면 '이번 모집은 지원 전에 할 일이 없습니다.' 미충족이면 지원서·근거 없는 일정(다음 모집 등) 줄을 빼고, 없으면 같은 문장
- 보내는 학생 정보: 허용 목록만(`backend/agent/payload.py`), 이름·이메일·계정 ID는 보낼 길이 없음
- 공고 속 지시문 무시, 합격 가능성 언급 금지: 지침에 있으므로 **지우지 말 것**

## 지침에서 지키는 형식 (앱 화면이 기대함)

- 칸마다 줄바꿈으로 나눈 짧은 줄. 앱은 줄 하나를 항목 하나로 그린다
- `fit` 줄 앞 '맞음: / 안 맞음: / 확인 필요:', `eligibility` 첫 줄 '충족: / 미충족: / 확인 필요:'(뒤에 판정을 가른 조건) → 앱이 색 꼬리표로 보인다(`apps/mobile/lib/ui/agent_flow.dart`의 `splitLineTag`). 낱말을 바꾸면 앱도 같이 바꿔야 한다
- `skills`는 20자 이내 줄 최대 4개, 우대는 줄 끝 '(우대)' → 앱이 칩으로 보인다. 알 수 없으면 '제공된 공고 정보에서 요구 역량을 확인하기 어렵습니다' 한 문장 → 앱은 일반 문장으로
- 문체: 합쇼체·명사형(해요체·평서형 금지, D-020)

## 기록

- 저장본 키에 버전이 들어간다(`report_cache.cache_key`). 저장된 리포트 문서에 `harness_version`, 서버 로그 `analysis created … harness=…`
