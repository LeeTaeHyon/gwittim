# 지원 조건 판정·추천 순위 수정 명세

- 작성일: 2026-11-10
- 상태: **제안 (팀장 승인 전, 미구현)**
- 근거 문서: [SPEC.md](../SPEC.md) §5·§6, [next-work-spec.md](next-work-spec.md) T5, [decisions.md](decisions.md) D-005 #5·D-020·D-023
- 이 문서는 수정 범위와 완료 기준만 정한다. 코드·계약·샘플은 아직 바뀌지 않았다.

## 1. 확인된 문제

2026-11-10에 저장소 코드를 그대로 불러 실행해 재현했다.

### F1. 제한 없음 문구가 있으면 미해석 조건·불완전 추출이 있어도 `met`

| 본문 | explicitly_unrestricted | extraction_complete | 미해석 | 판정 |
|---|---|---|---|---|
| `학년 제한 없음` / `소득분위 3분위 이하` (두 줄) | true | false | 1 | met |
| `지원자격: 학년 제한 없음, 소득분위 3분위 이하` (한 줄) | true | false | 1 | met |
| `학년 제한 없음` + 첨부 1개 | true | false | 0 | met |
| `학년 무관, 소득분위 3분위 이하` | true | true | 0 | met |

- `evaluate`가 `explicitly_unrestricted`를 맨 먼저 보고 `met`을 돌려준다 (`backend/recommendation/eligibility.py:19-20`). 미해석·불완전 검사(`:36-41`)에 닿지 않는다.
- 규칙 분석기의 `explicit`은 `conditions`가 비었는지만 본다 (`backend/analysis/rules.py:427`).
- LLM 보강은 미해석 조건을 더해도 `explicit`을 끄지 않는다 (`backend/analysis/llm.py:191-192`, `:203-205`).
- 넷째 줄: `NOT_CONDITION`의 `무관`이 줄 전체를 조건 아님으로 처리해 소득 조건이 사라진다 (`rules.py:181`, `:421`).
- 어긴 규칙: SPEC §6 지원 조건(`SPEC.md:185-186`), T5 사례표(`next-work-spec.md:125`, `:128`, `:129`), SPEC §5(`SPEC.md:139`, 모집 제한 없음이 명시된 경우에만 true).

### F2. 학과 통계만 맞는 공고가 고른 관심사와 맞는 공고보다 앞섬

컴퓨터공학과, 관심사 `public_service`, 두 공고 모두 마감 8일 전.

| 공고 | 요소 | 점수 |
|---|---|---|
| A: 관심사 꼬리표 `public_service` | interest 1.0, major_prior 0.0058, timing 1.0 | 71.59 |
| B: 관심사 꼬리표 없음, 직무 꼬리표 `software_developer` | major_prior 1.0, timing 1.0 | 100.0 |

- 공고에 꼬리표가 없으면 그 요소가 평가 불가가 되고(`backend/recommendation/scoring.py:14-15`), 공고마다 분모에서 빠진다(`:54-56`). 분모가 A는 70, B는 30이다.
- 추천 5의 식(`SPEC.md:197`)은 그대로 구현돼 있다. 추천 4·D-020의 "고른 분야가 앞서고"(`SPEC.md:196`, `decisions.md:1048`)가 공고 사이에서 지켜지지 않는다. 명세 안의 충돌이다.

## 2. 수정 범위

두 작업은 서로 독립이다. PR을 나눈다.

### W1. 지원 조건 판정 (F1)

**W1-a. 조건 비교** — `backend/recommendation/eligibility.py`

- `met`을 바로 돌려주는 조건을 다음 셋이 모두 참일 때로 좁힌다.
  - `explicitly_unrestricted`
  - `extraction_complete`
  - `unresolved_conditions`가 비어 있음
- 그 밖의 경우는 아래 일반 판정으로 내려가 `needs_check`가 된다(빈 `conditions`는 이미 불완전으로 본다).
- 함수 설명의 "명시적 제한 없음 → met" 줄을 같은 조건으로 고친다.
- 우대 사항(`note`가 '우대 사항')만 남은 경우도 지금처럼 `needs_check`로 둔다. 따로 다루지 않는다.

**W1-b. 규칙 분석기** — `backend/analysis/rules.py`

- `explicit`은 제한 없음 문구가 있고, `conditions`가 없고, 정리한 `unresolved`도 없을 때만 true.
- 제한 없음 문구(`UNRESTRICTED`)에 걸린 줄은 `NOT_CONDITION` 면제를 받지 않는다. 같은 줄에 `UNRESOLVED` 낱말이 있으면 미해석 조건으로 남긴다.
- `ANALYSIS_VERSION`을 `rule-0.8`로 올리고 머리 주석에 한 줄을 더한다.

**W1-c. LLM 보강** — `backend/analysis/llm.py`

- 합친 `unresolved_conditions`가 있으면 `explicitly_unrestricted=False`, `unrestricted_evidence=None`으로 내린다. 올리지는 않는다.

**하지 않는 것**

- 스키마(`contracts/common.schema.json`)·`schema_version` 변경 없음. 지금 조건(`conditions` 비어 있음, 근거 있음)은 그대로 유효하다.
- "학년 제한 없음"을 학년 조건 충족으로 따로 표시하는 기능은 넣지 않는다.
- 앱 코드 변경 없음.

### W2. 추천 점수 (F2)

**W2-a. 점수 요소** — `backend/recommendation/scoring.py`

- 관심사·직무 요소(`_overlap`)
  - 프로필에 값이 없으면 평가 불가(`None`). 지금과 같다.
  - 프로필에 값이 있고 공고 꼬리표가 없으면 `0.0`(불일치). 지금은 `None`이다.
- 전공(`major`), 학과 통계(`major_prior`), 시기(`timing`)는 그대로 둔다.
- `backend/recommendation/config.py`의 `RANKING_VERSION`을 `rank-0.6`으로 올린다. 가중치는 그대로다.

**W2-b. 명세** — `SPEC.md` §6 추천 5

- "사용자 미입력 또는 공고 정보 부족으로 평가 불가능한 요소는 분모에서 제외한다"에 예외를 적는다: 학생이 관심사·직무를 골랐는데 공고에 그 꼬리표가 없으면 불일치(0)로 평가한다.
- `docs/decisions.md`에 새 항목으로 날짜·결정·이유를 남긴다. 번호는 작성 시점의 다음 번호를 쓴다.

**바뀌는 동작**

- 관심사나 직무를 고른 학생에게는 꼬리표 없는 공고가 '점수 없음' 대신 낮은 점수를 받는다. 학과 통계만 맞는 공고의 점수가 내려간다.
- 학과만 입력한 프로필은 계산이 그대로다.
- F2 반례는 손계산으로 A 71.59, B 42.86이 된다. 구현 후 실행으로 확인한다.

**하지 않는 것**

- 가중치·시기 구간 변경, 학과 통계를 동점 정렬 기준으로 옮기는 변경.
- 응답 스키마 변경.

## 3. 회귀 테스트

### W1 — `backend/recommendation/tests/test_recommendation.py`

| 입력 | 기대 |
|---|---|
| 0003 샘플 그대로 | `("met", [])` (기존 테스트 유지) |
| 0003 사본에 미해석 조건 1개 추가 | `("needs_check", [])` |
| 0003 사본의 `extraction_complete=False` | `("needs_check", [])` |

### W1 — `backend/analysis/tests/test_analysis.py`

| 본문 | 기대 |
|---|---|
| `학년 제한 없음` / `소득분위 3분위 이하` | explicit false, 미해석에 소득 문구, complete false |
| `지원자격: 학년 제한 없음, 소득분위 3분위 이하` | 위와 같음 |
| `학년 무관, 소득분위 3분위 이하` | 위와 같음 |
| `학년 제한 없음` + 첨부 1개 | explicit true, complete false, `evaluate`는 `needs_check` |
| `학년·학과 제한 없이 누구나 참여 가능` | explicit true (기존 테스트 유지) |

- LLM 보강: 규칙 결과가 explicit true인 공고에 LLM이 받아들여지는 미해석 조건 1개를 내면 explicit false·근거 null. 기존 LLM 테스트의 가짜 응답 방식을 따른다.

### W2 — `backend/recommendation/tests/test_recommendation.py`

- F2의 A·B 공고(0003 사본, 꼬리표만 교체)와 컴퓨터공학과 + `public_service` 프로필로 `recommend` 호출.
  - A가 B보다 앞에 온다.
  - A에 `interest_match`, B에 `major_prior_match`가 있고 `interest_match`는 없다.
  - 응답 스키마 오류 없음.
- `test_major_only_profile_ranks_by_major_stats`, `test_chosen_interest_outranks_major_stats`가 그대로 통과한다.

## 4. 영향과 절차

| 대상 | W1 | W2 |
|---|---|---|
| 공통 계약 | 스키마 변경 없음. 판정 의미가 SPEC 문구대로 좁아짐 | SPEC §6 추천 5 문구 변경 → AGENTS §3 절차 |
| 팀장 승인 | 필요(판정·분석 버전 변경) | 필요(SPEC 변경) |
| 샘플 | 기존 샘플 유효. 필요하면 거부·경계 샘플 추가 | 점수가 든 추천 응답 샘플·앱 샘플 다시 생성(`tools.export_mobile_sample`) |
| 저장된 공고 | `rule-0.8`로 다시 분석해야 반영 | 해당 없음 |
| 배포 | API 다시 배포(팀장 요청 시) | API 다시 배포(팀장 요청 시) |
| 앱 | 변경 없음. 리포트의 '누구나 지원 가능' 표시가 줄어듦 | 변경 없음. 목록 순서만 바뀜 |

## 5. 완료 기준

- §3의 테스트가 추가되고 `uv run pytest` 전체가 통과한다.
- `tools/validate_contracts.py`가 통과한다.
- W1: §1 F1 표의 네 본문이 모두 `needs_check`로 나온다.
- W2: F2 반례에서 A가 B보다 앞선다. 실제 수집 공고로 D-020 확인(관심사 하나 고른 프로필의 상위 5 안 고른 관심사 일치 공고 수)을 다시 재고 전후 수치를 PR에 적는다.
- W2: SPEC·decisions·샘플·코드가 같은 PR에 들어간다.
- `docs/handoff.md`에 상태를 적는다.

## 6. 미확인·열린 사항

- 수정안은 실행해 보지 않았다. W2의 수치는 손계산이다.
- W1-b로 '성적 무관 누구나' 같은 줄도 확인 필요로 내려간다. 저장된 공고에서 몇 건이 `met` → `needs_check`로 바뀌는지는 재분석 전후로 세어야 한다.
- W2로 꼬리표 없는 공고가 점수를 받게 되면서 목록 상위가 얼마나 바뀌는지는 실제 공고로 재야 한다.
- 앱 화면은 확인하지 않았다.
