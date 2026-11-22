# P9 API 전환 준비 (구독 CLI → API)

> **2026-11-22 변경(D-044): 서비스 제공자를 DeepSeek Platform으로 바꿨다.** 0절이 지금 기준이다. 1~4절은 Anthropic 기준으로 준비한 기록이며, 코드 쪽 1~3번(생각 토큰, 월 상한, Cloud Run fake 차단)은 DeepSeek에도 그대로 적용된다.

## 0. DeepSeek 기준 (2026-11-22 확인)

| 항목 | 내용 | 출처 |
|---|---|---|
| 모델 id | `deepseek-flash` (DeepSeek-V4.1-Flash-1017) | api-docs.deepseek.com 가격 페이지 |
| 가격 | 입력(캐시 미적중) $0.15, 출력 $0.60 / 100만 토큰. 피크(평일 UTC 01~04·06~10시 = 한국 10~13·15~19시)는 2배 | 같은 페이지 |
| 생각 정도 | `reasoning_effort`: none / low / high / max, 기본 high. 코드는 none(생각 끔, 2026-11-22 비교로 low에서 변경) | Thinking mode 문서 |
| 출력 형식 | `response_format: json_object`만. JSON 스키마 강제 없음. 지시문에 'json' 낱말과 예시 필요. JSON이 아니면 공백으로 옴 | JSON mode 문서 |
| 웹 검색 | `tools: [{"type": "deepseek_web_search"}]`. 11/18부터 모델 호출 안의 검색은 따로 과금 안 함(결과는 입력 토큰) | Web tools 문서 |
| 서버·학습 | 서버 중국. 입력을 학습에 쓸 수 있음. 학습 거부 설정이 API에 적용되는지 명시 없음. 보관 기간 명시 없음 | DeepSeek 개인정보처리방침(2026-05-06판) |
| 최소 충전 | $2 (팀장이 결제 화면에서 확인, 공식 문서에서는 미확인) | |

사람이 할 일 (순서대로)

1. DeepSeek Platform 가입, 충전
2. 설정에서 학습 거부('모두를 위해 모델 개선' 끄기)가 있으면 끔
3. API 키 만들기. 저장소·앱·대화에 붙이지 않음(AGENTS.md §4). 로컬은 사용자 환경변수 `DEEPSEEK_API_KEY`, Cloud Run은 Secret Manager → 같은 이름 환경변수
4. 로컬 확인: `GWITTIM_LLM_PROVIDER=deepseek`로 로컬 서버 → 에뮬레이터 앱에서 상세 분석 1건 → 로그에 토큰 수·`cost_krw`가 찍히는지, 리포트 4칸이 다 오는지
5. Cloud Run에 `GWITTIM_LLM_PROVIDER=deepseek` 설정 후 배포 → 실제 호출 1건
6. 처리방침 공개본 갱신(P8): 받는 곳 DeepSeek, 학습·보관 문구, 계약 법인명·이용약관 확인

- 작성: 2026-11-21
- 왜: 2차(최종) 심사 때 APK를 내면 외부 사용자가 생긴다. 구독 CLI는 본인 사용 범위라 그 전에 API로 바꿔야 한다
- 기한: 최종보고서 12/11 전, APK 빌드 전
- 근거: `docs/agent-privacy-spec.md` §3·§6(P9), D-039(모델·비용 상한)

## 1. 확인한 사실 (2026-11-21)

| 항목 | 내용 | 출처 |
|---|---|---|
| 모델 id | `claude-haiku-5-5` (지금 코드 그대로) | Claude API 문서(모델 표) |
| 가격 | 입력 $0.10, 출력 $0.50 / 100만 토큰 (프롬프트 10만 토큰까지. 넘으면 $0.50 / $2.50) | 같은 표. D-039·`tools/llm_compare.py` 기록과 같음 |
| 보관 | API 입력·출력은 받은 뒤 30일 안에 삭제 | privacy.claude.com "How long do you store my organization's data" |
| 보관 예외 | 이용 정책 위반 판정 시 최대 2년, 피드백 5년, 법적 요구 | 같은 문서 |
| 학습 | 상업 제품(API) 입력·출력은 기본적으로 학습에 쓰지 않음. 예외: 피드백·버그 신고를 직접 보낸 경우, 사용자가 허용한 경우 | privacy.claude.com "Is my data used for model training" |
| Haiku 5.5 특성 | 생각(thinking)이 기본으로 켜져 있고 effort 기본값 `medium`. 생각 토큰도 `max_tokens` 안에서 쓰임 | Claude API 문서 |

- 처리방침 초안(#110 병합)의 "30일 안에 삭제, 학습에 쓰지 않음"은 위와 맞음. 기준일을 2026-11-21로 고쳐 적으면 됨

## 2. 코드에서 고칠 것 (P9 전 PR 하나)

- 1~3번은 PR #121에 구현(2026-11-21, 검토 중). 4번은 결정만

1. **생각 토큰 때문에 리포트가 잘릴 수 있음**
   - 지금 `API_MAX_TOKENS = 2000`인데, Haiku 5.5는 생각이 기본으로 켜져 있어 그 안에서 생각 토큰을 먼저 쓴다. 리포트 JSON이 중간에 끊기면 `ReportFormatError` → 환불 → 사용자는 실패만 봄
   - 고칠 방향: 요청에 `output_config: {effort: "low"}`, `max_tokens` 4000~8000으로. 4칸 JSON 정리는 깊은 추론이 필요 없음
   - 더 확실하게: 구조화 출력(`output_config.format`에 4칸 JSON 스키마)을 쓰면 4칸이 빠지는 일이 없어짐
2. **월 비용 상한 3만 원이 아직 구현 안 됨 (D-039)**
   - 계획: 그달 추정 비용(로그의 `cost_krw` 합)을 Firestore에 누적하고, 3만 원을 넘으면 새 상세 분석을 멈추고 안내. 받은 리포트는 계속 보임
   - 하루 서버 전체 상한(약 300건)은 D-039 "정할 것"에 남아 있음
3. **Cloud Run에서 fake 제공자로 뜨는 사고 막기**
   - 기본 제공자가 `fake`라서, 환경변수를 빠뜨리면 합성 리포트를 주면서 크레딧을 차감함(밤 검토 R1)
   - 고칠 방향: `K_SERVICE`가 있는데 제공자가 fake면 시작을 거부하거나 "준비 중"으로
4. **SDK는 쓰지 않음 (2026-11-21 팀장 결정)**
   - 표준 라이브러리(urllib)로 계속 부른다. 요청 종류가 하나(리포트 4칸)라 SDK 이점이 작다
   - SDK가 해 주는 일 중 필요한 것(바쁠 때 다시 시도, 4칸 JSON 스키마)은 지금 코드에 직접 넣는다
   - 확장 가능성: 요청 종류가 늘거나(외부 공고 찾기, 대화형 기능) 스트리밍·도구 호출이 필요해지면 공식 SDK(`anthropic`)로 바꾼다. 바꿀 곳은 `backend/agent/llm.py`의 `ApiProvider` 한 곳이고, 새 라이브러리라 AGENTS.md §2 승인이 필요하다

## 3. 사람이 할 일 (순서대로)

1. Anthropic Console 가입, 결제 수단 등록
2. Console에서 월 사용 한도 설정: 3만 원(약 $21) 근처로. 코드의 상한과 별개로 두 번째 안전장치
3. API 키 만들기: 귀띔 전용 workspace를 따로 두면 사용량·키 관리가 쉬움
4. 키는 저장소·앱에 넣지 않음(AGENTS.md §4). Cloud Run에는 Secret Manager에 넣고 환경변수 `ANTHROPIC_API_KEY`로 연결
5. 로컬에서 먼저 확인: 키를 환경변수로 두고 `GWITTIM_LLM_PROVIDER=api`로 로컬 서버 → 에뮬레이터 앱에서 상세 분석 1건 → 로그에 토큰 수·`cost_krw`가 찍히는지
6. Cloud Run에 `GWITTIM_LLM_PROVIDER=api` 설정 후 배포 → 실제 호출 1건 확인
7. 처리방침 공개본 갱신(P8): 배포 문구 다시 넣기, Anthropic 보관 기준일 갱신
8. 만료 리포트 삭제 작업 연결과 Firestore collection group 색인(`expires_at`)

## 4. 비용 감

- 리포트 1건: 입력 약 3,000토큰 + 출력 약 1,500토큰이면 약 1.5원. D-039 측정값은 약 3.3원(생각 토큰 포함 추정)
- 사용자 1,000명 × 월 5건이면 월 약 1만 7천 원(D-039 추정). 상한 3만 원 안

## 5. 팀장이 정할 것

- 하루 서버 전체 상한 건수
- 상한에 걸렸을 때 앱 문구
- Console 월 한도 금액
