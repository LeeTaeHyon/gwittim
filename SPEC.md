# 귀띔 (Gwittim) — 공통 개발 명세

- 버전: 0.6
- 작성일: 2026-10-16 / 0.2 갱신: 2026-10-17 (D-005 계약 결정 반영, `contracts/` 초안 작성) / 0.3 갱신: 2026-10-26 (D-013 수집 게시판 4개, 오래된 마감 미상 공고 추천 제외, D-014 이미지 대체텍스트) / 0.4 갱신: 2026-10-30 (D-019 카카오톡 알림톡 출처, 알림톡 분류 모델) / 0.5 갱신: 2026-10-30 (D-020 학과 통계 보조 점수, 프로필 학과 통계 칩) / 0.6 갱신: 2026-10-30 (D-021 학과 통계 추천 분리 표시와 관심 있음·없음)
- 상태: 구현 착수용 제안 초안. 팀 합의 후 기준 버전으로 사용한다.
- 대상: 팀장, 팀원, 각자의 AI 코딩 에이전트
- 이 문서는 목표 동작을 정의한다. 구현 완료를 의미하지 않는다.

## 1. 목표

학생이 몰랐던 교내외 기회를 발견하고, 지원 조건과 원문을 확인한 뒤 저장할 수 있는 Android 앱을 만든다.

핵심 흐름: 공고 수집 → 정규화·분석 → 검증·저장 → 지원 조건 비교 → 추천 → 상세·원문 확인 → 저장.

우선순위는 데이터 정확성, 전체 흐름 연결, 개인화, 화면 완성도 순이다. 신규 기능보다 동작하는 핵심 흐름을 우선한다.

## 2. P0 범위와 제외 범위

### 11월 6일 중간보고 목표

- 명지전문대 www 공개 게시판 4개(공지사항·장학공지·채용공지·근로게시판)에서 실제 공고 수집 (D-013).
- 명지전문대 카카오톡 채널 알림톡의 공통 공지 게시 (D-019). 팀장 PC 카톡의 대화 내보내기 파일을 수동으로 넣고, 개인 알림·참여자 전용 안내는 게시하지 않는다. 카테고리·관심사는 알림톡으로 학습한 분류 모델이 붙이고, 애매하면 로컬 LLM이 판단한다. 연도 없는 날짜('9월 11일(금)까지')는 발송일 근처의 해로만 읽고, 마감일 없이 행사일만 있는 알림톡은 그 날짜가 지나면 끝난 공고(closed)로 본다. 이미 끝난 알림톡은 게시하지 않는다.
- 중복 저장 방지, 수정 감지, 수집 실패 기록.
- 공고 구조화와 날짜·지원 조건 검증. 해석이 필요한 본문에 LLM 적용.
- 기본 인증, 사용자 프로필 입력·수정.
  - 학과를 고르면 관심 분야 단계에 그 학과 졸업생이 많이 가는 분야 3개를 참고로 먼저 보인다. 미리 고르지 않고 학생이 눌러야 저장한다(D-020).
- 학과·학년·재학 상태 기반 지원 조건 비교.
- 관심사·희망 직무·전공 기반 규칙 추천과 추천 이유.
  - 학과 통계로만 고른 공고(고른 관심사·직무·전공과는 관련 없음)는 마감 임박·새 공고에 섞지 않고 '학과 통계 추천' 표시를 붙여 따로 보인다. 학생이 '관심 있어요/없어요'로 답하고, '관심 없어요'가 3번 이어지면 30일 쉰다. 답은 기기에만 남긴다(D-021).
- Android 추천 피드, 상세 화면, 원문 연결.
- 앱 내부 공고 저장과 마감일 목록.

학교 이용 허락이 지연되면 이용조건이 확인된 공식 API로 전체 흐름을 먼저 연결한다. 이 경우 교내 연동이 완료됐다고 보고하지 않는다.

### P0 제외

위 4개 게시판과 알림톡 외 출처 확대(홍보게시판, ctl 비교과, 다른 사이트), 알림톡 자동 수신, 받은 사람의 개인 알림함, 임베딩 추천, 학습 기반 추천(점수·순위를 학습. 꼬리표 분류 모델은 D-019, 공개 통계 기반 학과 보조 점수는 D-020으로 포함), 피드백 가중치 학습, 개인 시간표, 일정 충돌 검사, 기기 캘린더 연동, 푸시 알림, 대화형 비서, LLM 실시간 브리핑, iOS.

토스형 브리핑 표현은 참고하되 P0에서는 저장된 데이터와 문장 템플릿으로 표시한다. 타 서비스 화면·자산을 복제하지 않는다.

## 3. 일정과 검증 지점

| 기간 | 목표 | 완료 기준 |
|---|---|---|
| 10/16~18 | 개발 준비 | 출처 확인·신청, 데이터 계약, 샘플 JSON, 역할 경계 합의 |
| 10/19~23 | 시험주간 | 신규 기능 필수 일정 없음. 승인 답변·차단 사항만 확인 |
| 10/24~30 | M1 첫 통합 | 실제 공고 수집 → 분석 → 저장 → Android 목록·상세·원문 연결 |
| 10/31~11/3 | P0 기능 연결 | 프로필별 조건 비교·추천, 공고·마감일 저장 |
| 11/4~6 | 검증·보고 | 오류 수정, APK·영상·중간보고서 준비 |

M1의 수동 검증 표본은 20건을 목표로 한다. 부족하면 실제 건수와 사유를 기록한다. P0에서는 서로 다른 프로필 3개로 추천 차이를 확인한다. 수치는 검토자 제안 목표이며 실적이 아니다. 대회 마감일은 제공된 기획서 기준이며 공식 공지 변경 여부는 팀장이 확인한다.

## 4. 기술 구성과 경계

| 영역 | P0 기준안 | 책임 |
|---|---|---|
| 앱 | Flutter / Dart, Android | 입력·조회·표시·저장 요청 |
| 데이터·인증 | Firebase Authentication / Firestore | 사용자별 접근 분리, 공고·프로필·저장 데이터 |
| 수집·분석 | Python 배치 | 수집, 정규화, LLM 추출, 검증, 게시 |
| 추천 | Python 순수 로직 + 인증된 서버 API | 조건 비교·점수·추천 이유 생성 |
| 서버 실행 | Cloud Run 또는 Cloud Functions 중 하나 선정 | 사용자 요청 처리. 중복 백엔드 도입 금지 |
| LLM | 교체 가능한 분석 인터페이스, 로컬 우선 평가 | 본문 구조화. 유료 API는 기본 의존성 아님 |

실행 환경이 결정되기 전에도 순수 추천 함수와 앱의 샘플 데이터 구현은 진행할 수 있어야 한다. 로컬 배치가 중단돼도 이미 게시된 공고 조회·추천은 가능해야 한다. 실제 운영 비용이 0원임을 보장하지 않는다.

## 5. 공통 데이터 계약

이 문서는 필드의 의미를 정의한다. 실제 타입·필수값·열거값 검증은 `contracts/`의 JSON Schema로 관리하고 `uv run python tools/validate_contracts.py`로 `fixtures/`와 함께 검증한다. 문서와 스키마를 같은 PR에서 갱신한다.

### 공통 규칙

- JSON 필드는 snake_case. ID는 불투명 문자열로 취급한다.
- 타임스탬프는 UTC ISO 8601. 날짜만 있는 값은 YYYY-MM-DD와 원문 시간대를 별도로 보존한다.
- 시간대가 확인되지 않으면 임의로 확정하지 않는다. 국내 출처의 Asia/Seoul 적용은 어댑터 설정에 근거를 남긴다.
- `null`은 미상·미제공이다. 빈 조건 배열은 지원 제한이 없다는 뜻이 아니다.
- 사용자 제공 정보와 추출·추정 정보를 구분한다. 사용자 정보를 임의 추정하지 않는다.
- 스키마 버전과 공고 버전·분석 버전을 구분한다.

### RawNotice — 수집기 출력

| 필드 | 타입 | 의미 |
|---|---|---|
| schema_version | string | 계약 버전, 초기 1.0 |
| source_id | string | 출처 설정의 고유 ID |
| source_notice_id | string 또는 null | 출처가 제공하는 공고 ID |
| source_url | string 또는 null | 원문 URL. 웹 원문이 없는 출처(카카오톡 알림톡, D-019)는 null이고 이때 source_notice_id가 필수 |
| title | string | 원문 제목 |
| body_text | string | 메뉴·푸터를 제거한 본문. 본문 이미지의 대체텍스트(alt)는 `[이미지 설명]` 줄 아래에 붙인다(D-014) |
| published | object 또는 null | 원문 게시일 날짜 정보. 날짜만 있으면 precision=date, 미표기는 null |
| collected_at | string | 이번 수집 시각 |
| content_hash | string | `sha256:<hex>`. title·body_text·published·source_fields·첨부 파일명의 해시 |
| source_fields | object | 출처가 제공한 날짜·대상·작성 부서 등 원래 필드. 조회수처럼 매번 바뀌는 값 제외 |
| attachments | array | file_name·url(직접 URL 없으면 null)·type. 배열에 있다고 다운로드 허용된 것은 아님 |

수집기는 DB 저장을 직접 책임지지 않는다. 저장·분석은 공통 파이프라인에서 처리한다. 수집시각처럼 매번 달라지는 값은 content_hash에서 제외한다.

### Notice — 앱이 사용하는 공고

| 필드 | 타입 | 의미 |
|---|---|---|
| schema_version / notice_id | string | 계약 버전 / 내부 ID |
| source_id / source_url | string / string 또는 null | 출처 / 원문 링크 (알림톡은 null, 앱은 원문 열기 대신 안내를 보인다) |
| title | string | 표시 제목 |
| summary | string 또는 null | 검증된 요약 |
| category | string | 공통 카테고리 코드 |
| interest_tags / related_majors / related_roles | string 배열 | 공통 사전 코드 |
| published | object 또는 null | 게시일 날짜 정보. 추천 동점 정렬에 사용 |
| application_start | object 또는 null | 신청 시작 날짜 정보 |
| application_deadline | object 또는 null | 신청 마감 날짜 정보 |
| deadline_note | string 또는 null | 확정 날짜가 아닌 마감 설명 원문 (선착순, 예산 소진 시 등) |
| activity_period | object 또는 null | 확인된 활동 기간 `{start, end, evidence}`. start·end는 날짜 정보 또는 null |
| eligibility | object | 조건·미해석 조건·추출 완전성 |
| lifecycle_status | string | open / closed / unknown / removed |
| publication_status | string | published / review_pending |
| notice_version / analysis_version | integer / string | 공고 변경 버전(원문 content_hash 변경 시만 증가) / 분석기 버전 |
| last_collected_at / last_verified_at | string 또는 null | 수집 / 원문 정상 확인 시각 |
| changed_fields | string 배열 | 직전 버전 대비 변경된 Notice 최상위 필드명 |

날짜 정보 구조: `date`(YYYY-MM-DD), `time`(HH:MM, 미상은 null), `timezone`(IANA 이름, 미상은 null), `precision`(date 또는 minute), `evidence`(원문 문구, 필수). precision이 minute이면 time이 있어야 하고 date이면 time은 null이다.
‘선착순 마감’이나 ‘예산 소진 시’는 확정 마감일로 바꾸지 않고 `deadline_note`에 원문 설명으로 보존한다. 날짜만 확인된 당일에는 임의의 마감시각을 보여주지 않는다.

### EligibilityCondition — 조건

```json
{
  "field": "grade",
  "operator": "in",
  "value": [2, 3],
  "evidence": "2~3학년 재학생 대상",
  "validation_status": "validated"
}
```

P0 자동 비교 지원 필드는 university_id, major_id, grade, enrollment_status이며 연산자는 eq, in이다. 필수 조건은 AND로 평가한다. 복잡한 OR·예외·연령·소득·학점 등은 `unresolved_conditions`에 보존한다.

`eligibility`에는 `conditions`, `unresolved_conditions`, `extraction_complete`, `explicitly_unrestricted`, `unrestricted_evidence`를 둔다. 모집 제한 없음이 원문에 명시된 경우에만 `explicitly_unrestricted`를 true로 하고 근거를 남기며, 이때 conditions는 비어 있어야 한다. 그 외의 빈 conditions는 조건을 찾지 못한 상태다. 첨부파일에 조건이 있으나 미처리했다면 extraction_complete는 false다. LLM의 자기 확신만으로 true를 확정하지 않는다.

### UserProfile — 사용자 입력

university_id, major_id, grade, enrollment_status, interest_ids, target_role_ids, updated_at.

- 학교·학과·상태·관심사·직무는 공통 선택 사전(`contracts/dictionaries/`)을 사용한다. 코드는 학교 접두사를 붙인 불투명 ID다(예: `mjc`, `mjc.computer_engineering`).
- grade는 1~4 정수, enrollment_status는 enrolled / on_leave / graduated.
- 미입력은 null 또는 빈 선택 배열로 보존한다.
- 성적·소득·주민등록번호·학생증은 수집하지 않는다.
- 사용자 ID는 인증 정보에서 얻는다. 요청 본문의 사용자 ID를 신뢰하지 않는다.

### RecommendationItem — 추천 출력

notice_id, notice_version, score, eligibility_status, condition_results, reason_codes, generated_at, ranking_version.

- eligibility_status: met / not_met / needs_check.
- condition_results: 각 조건의 `field`, `status`(met / not_met / unknown), `evidence`, `unknown_reason`(profile_missing / condition_unresolved / extraction_incomplete, unknown일 때만).
- score는 내부 순위용이며 합격 확률·지원 가능 확률이 아니다.
- reason_codes(interest_match, role_match, major_match, major_prior_match, deadline_timing, eligibility_met, eligibility_needs_check)는 실제 점수 기여·판정 근거에서 생성한다. 앱은 공통 템플릿으로 표시한다.
- 추천 목록 응답의 `mode`는 personalized 또는 latest다. latest(개인화 불가)이면 score는 null이고 게시일 내림차순이다. personalized에서도 관심사·직무·전공을 하나도 평가할 수 없는 공고는 score null로 점수 있는 공고 뒤에 둔다.

### SavedNotice — 저장

notice_id, saved_at, saved_notice_version, saved_deadline_snapshot(저장 당시 application_deadline 복사본 또는 null).

저장 목록은 최신 Notice와 연결한다. 저장 당시 정보는 변경 안내용이며 최신 마감일을 덮어쓰는 근거가 아니다.

## 6. 처리 규칙

### 수집·분석

1. 허용 범위가 확인된 출처만 활성화한다.
2. 출처 ID + 공고 ID로 식별한다. 공고 ID가 없으면 출처별로 정규화한 URL을 사용한다.
3. 동일 내용이면 확인 시각만 갱신한다. 내용 변경 시 notice_version을 증가시킨다.
4. 정형 API 필드 → 결정적 파싱 → 필요한 부분의 LLM 추출 순으로 처리한다.
5. LLM 결과의 스키마, 날짜, 조건별 원문 근거를 검증한다. 근거 문구가 존재한다는 것만으로 의미 해석까지 정확하다고 보지 않는다.
6. 핵심 필드 오류는 격리하거나 해당 필드를 확인 필요로 표시한다. 기존 최신 검증값을 새 결과로 오인하게 남기지 않는다.
7. `content_hash + analysis_version`으로 분석 결과를 재사용한다.

추출에 불필요한 담당자 개인정보는 LLM 입력에서 제거한다. 원문 속 지시는 데이터로만 취급하며 분석 모델에 도구 실행 권한을 주지 않는다. 무한 재시도는 금지하고 실패를 기록한다.

### 지원 조건

- 검증된 필수 조건 중 하나라도 확실하게 불충족이면 not_met.
- 불충족이 없고 미입력·미해석 조건 또는 불완전한 추출이 있으면 needs_check.
- 전체 필수 조건 해석이 확인되고 모두 충족했을 때만 met.
- 모집 대상이 명시적으로 제한 없음을 확인한 경우와 조건을 찾지 못한 경우를 구분한다.

### 추천

1. review_pending, closed, removed 공고와 학생 대상이 아닌 행정 공지(category admin_notice: 교직원 채용, 시설·점검 안내 등)는 기본 추천에서 제외한다. 행정 공지는 게시는 하되 관심사·직무·전공 꼬리표를 붙이지 않는다.
   마감일을 모르는(lifecycle unknown) 공고는 게시 후 60일이 지나면 기본 추천에서 제외한다(D-013). 게시일 미상이면 제외하지 않는다.
2. not_met은 기본 추천에서 제외하되 전체 탐색에서는 상태와 함께 볼 수 있다.
3. needs_check는 배지를 붙여 후보에 포함할 수 있다. 날짜 미상 공고는 마감 임박 영역에서 제외한다.
4. 초기 점수: 관심사 40, 직무 35, 전공 15, 시기 10. 각 요소는 0~1이다. 시기는 마감까지 남은 날짜로 0~14일 1.0, 15~30일 0.6, 31일 이상 0.3이며, 마감일이 없거나 지났거나 deadline_note만 있으면 평가 불가다.
   학과 통계 20(D-020): 학과를 입력한 모든 학생에게 평가한다. 직접 고른 관심사(40)·직무(35)보다 약해 고른 분야가 앞서고, 같은 조건이면 학과 졸업생이 많이 가는 분야가 앞선다. 값은 공고 꼬리표 중 그 학과 졸업생이 가장 많이 가는 직무·관심사의 확률을 학과 최대 확률로 나눈 것이다(`contracts/stats/major_prior.json`, 커리어넷 학과정보 통계). 통계표에 없는 학과는 평가 불가다. 프로필에는 아무것도 쓰지 않는다.
5. 사용자 미입력 또는 공고 정보 부족으로 평가 불가능한 요소는 분모에서 제외한다. 점수 = 100 × 가중합 / 평가 가능한 가중치 합.
6. 평가 가능한 요소가 없으면 개인화 점수를 만들지 않고 최신 공고 탐색으로 제공한다.
7. 동점은 게시일 내림차순, 내부 ID 순으로 정렬한다. 게시일 미상은 뒤에 둔다.
8. 연결 사전·가중치는 한 설정에서 관리하고 ranking_version을 기록한다.

추천 이유는 템플릿으로 만든다. ‘관심 분야 관련’과 ‘지원 조건 충족’을 구분한다. 마감 임박 여부를 무조건 높은 관심도 점수로 바꾸지 않는다.

### 실패·변경

- 단일 접속 실패나 HTTP 403만으로 삭제를 확정하지 않는다.
- 일시 장애 시 기존 게시 공고를 유지하고 마지막 확인 시각을 제공한다.
- 삭제 확인 시 추천을 중단하고 저장 목록에 상태를 표시한다.
- 마감일·조건 변경 시 최신 정보와 변경 표시를 제공한다. P0에서 푸시 도달을 보장하지 않는다.
- 새 분석 실패 시 예전 결과를 최신 검증 결과처럼 표시하지 않는다.

## 7. 앱·서버 인터페이스

논리 인터페이스를 먼저 고정한다. 실제 HTTP 경로·Firestore 접근 방식은 백엔드 선정 후 contracts와 함께 확정한다.

| 인터페이스 | 입력 | 출력 |
|---|---|---|
| get/update_profile | 인증 사용자, 프로필 | UserProfile |
| list_recommendations | 인증 사용자, limit, cursor | RecommendationItem + Notice 요약, next_cursor, generated_at |
| get_notice | notice_id | 공개된 Notice 또는 not_found |
| save_notice | 인증 사용자, notice_id | SavedNotice |
| delete_saved_notice | 인증 사용자, notice_id | 삭제 결과. 반복 요청 안전 |
| list_saved_notices | 인증 사용자, cursor | SavedNotice + 최신 공고 상태 |

인증 실패·권한 없음·입력 오류·미존재·일시 장애를 구분한다. 오류 응답은 `{error: {code, message}}`이고 code는 unauthenticated / permission_denied / invalid_argument / not_found / unavailable이다. 목록 응답은 items, next_cursor(불투명 문자열 또는 null), generated_at을 가지며 limit은 최대 50이다. 앱에 스택 추적·비밀키를 반환하지 않는다. 추천 페이지 이동 중 중복·누락을 줄이도록 초기에는 소량 결과를 한 번에 받아 표시해도 된다.

앱 데이터 접근은 Repository 인터페이스로 감싼다. 샘플 구현과 실제 구현을 교체할 수 있어야 한다. UI에 추천 점수 계산을 중복 구현하지 않는다.

## 8. 역할·파일 소유권 제안

팀장은 전체 의사결정과 통합을 주도한다. 담당자는 개발 소유권이며 검토·협업을 금지하는 의미가 아니다.

| 영역 | 주 담당 | 작업 경계 |
|---|---|---|
| SPEC·contracts·공통 사전 | 팀장, 팀원 검토 | 변경 전 영향 공유 |
| 분석·검증·추천·Firebase·보안 | 팀장 | 공통 계약에 맞춰 결과 제공 |
| 수집 어댑터 1개 | 팀원 | RawNotice 출력까지. 저장은 공통 코드 |
| Flutter 피드·상세·저장 UI | 팀원 | 샘플로 선행 개발. 팀장은 인증·연동 지원 |
| 통합·오류 검증·보고 | 팀장 주도, 공동 수행 | 원문 대비 검증·실기기 시연 |

수집기와 UI 동시 부담이 크면 팀장은 수집 파이프라인·배포를 맡고, 팀원은 어댑터 한 개와 화면에 집중한다. 같은 파일의 동시 수정은 피하고 PR 단위를 작게 유지한다.

권장 구조:

```text
SPEC.md
AGENTS.md
apps/mobile/
backend/collectors/
backend/analysis/
backend/recommendation/
backend/api/
contracts/
fixtures/
docs/decisions.md
docs/handoff.md
```

## 9. AI 코딩 에이전트 사용 규칙

- 한 작업은 한 산출물과 완료 기준으로 요청한다. 전체 앱 재생성 요청은 피한다.
- SPEC, 해당 계약, 관련 파일만 우선 읽는다. 전체 저장소 탐색이 필요하면 목적을 정한다.
- 승인되지 않은 기능·라이브러리·유료 API를 임의 추가하지 않는다.
- 공통 계약을 바꿔야 하면 이유·영향을 제시하고 문서·샘플·소비 코드를 함께 수정한다.
- 작업 종료 시 변경 파일, 실행한 검증, 남은 문제, 다음 작업을 짧게 남긴다.
- AI 생성 코드도 사람이 원문과 실행 결과를 확인한 뒤 병합한다.
- 상세 오류·코드·로그를 사용자용 화면에 그대로 노출하지 않는다.

## 10. 보안·개발환경

- 사용자 프로필·저장은 본인만 읽고 쓸 수 있게 한다.
- 공개 공고의 앱 클라이언트 쓰기는 금지한다. 서버의 관리자 권한 사용 경로는 별도로 입력·인증 검증한다.
- 원문 수집 자료·분석 로그·검토 대기 공고는 공개 컬렉션과 분리한다.
- LLM 키·서비스 계정·서명 키는 Git에 저장하지 않는다. `.env.example`에는 변수명과 설명만 둔다.
- 개발·운영 설정을 분리한다. 실제 운영 데이터로 수동 실험하지 않는다.
- 프로필 삭제·탈퇴 시 프로필, 저장 데이터, 개인화 데이터의 삭제 경로를 준비한다. 공개 공고는 유지한다.
- 외부 LLM에 사용자 프로필을 보내지 않는다. 공개 공고도 출처별 이용조건을 확인한다.

## 11. 완료 기준

### 개별 PR

- 요청 범위의 실제 실행 결과가 있다.
- 변경한 경계의 필요한 검증을 통과한다. 계약 변경은 소비자까지 확인한다.
- 임시 비밀키·테스트 계정·실제 개인정보가 포함되지 않는다.
- 미완료·미검증 사항을 숨기지 않고 PR에 기록한다.

### P0 통합

- 실제 공고가 앱까지 연결되고 원문이 열린다.
- 같은 공고 재수집 시 중복되지 않고 수정본은 구분된다.
- 알려진 마감일·자격 오류를 수정하거나 확인 필요로 처리한다.
- 프로필 3개에서 조건·추천 이유의 차이를 설명할 수 있다. 억지로 순서를 다르게 만들지 않는다.
- 저장·재조회·저장 취소가 동작한다.
- 다른 사용자의 프로필·저장 데이터에 접근할 수 없다.
- 일반 오류에서 앱이 종료되지 않고 재시도·빈 상태를 표시한다.
- 앱 실행에 사용자별 LLM 호출이 필요하지 않다.
- APK·시연 영상·검증표·알려진 한계를 제출물로 준비한다.

## 12. 착수 전 결정 목록

| 결정 | 담당 | 목표 |
|---|---|---|
| 첫 출처·수집/재사용 조건·실패 시 대체 출처 | 팀장 | 10/18 |
| Flutter·Dart·Python 버전과 의존성 고정 | 공동 | 10/18 |
| 인증 방식·서버 실행 환경 | 팀장 | 10/18 |
| 공통 ID·태그·학과/직무 사전·JSON Schema | 팀장, 팀원 검토 | 10/18 |
| 로컬 모델·실행 방식·라이선스·실제 추출 품질 | 팀장 | M1 전 |
| 수집 빈도·재시도 상한·오래된 정보 표시 기준 | 공동 | M1 전 |
| 공개 테스트 전 개인정보 안내·탈퇴 경로 | 팀장 | 테스트 전 |

핵심 합의 변경은 docs/decisions.md에 날짜·결정·이유를 남긴다. 이 문서만으로 출처 이용 허락, 특정 API 접근, 기술 호환성이 확인된 것으로 간주하지 않는다.
