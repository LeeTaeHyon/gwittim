# 배포·APK 빌드 절차 (반복용)

- 작성: 2026-11-23
- 목적: 남은 3주 동안 기능을 더하면서 **매주 같은 절차로** 서버와 앱을 올린다. 한 번에 몰아서 마무리하지 않는다
- 배포·리소스 생성은 팀장이 요청할 때만(AGENTS.md §2). 이 문서는 명령과 확인 순서를 정리한 것

## 0. 지금 상태 (2026-11-23 확인)

| 항목 | 값 |
|---|---|
| Cloud Run | `gwittim-api` (gwittim-dev, asia-northeast3), 리비전 `gwittim-api-00007-nxm` = main `075a4ff`(11/15) |
| 그 뒤 서버 변경 | 커밋 33개: 맞춤 에이전트(상세 분석·크레딧·리포트 저장·월 비용 상한), DeepSeek 제공자, 학교 선택(`unlisted`)·학교 공지 노출 규칙(rank-0.8), 숭의 사전, 분석 rule-0.9 |
| 환경변수 | `GWITTIM_FIREBASE_PROJECT_ID`, `GWITTIM_INGEST_TOKEN`(일반 환경변수로 들어 있음 → §2에서 Secret Manager로 옮기기 권장) |
| 보안 규칙 | `firestore.rules`는 11/15 이후 바뀐 것 없음 |
| 앱 | 버전 `0.9.0+2`(11/04 체험판), 디버그 키 서명(SHA-1이 Firebase에 등록됨) |
| 정기 배치 | `Gwittim-batch` = main `423faf0`(11/23 갱신, rule-0.10 졸업 예정자 직접 확인, 교외 출처 중복 묶기 D-048 포함) |

## 1. 배포 전 점검 (Claude가 함)

1. main 최신, `git status` 깨끗
2. `uv run pytest -q`, `PYTHONIOENCODING=utf-8 uv run python tools/validate_contracts.py`
3. `apps/mobile`에서 `flutter analyze`, `flutter test`
4. 이번 배포에 들어가는 변경 목록(지난 리비전 커밋 → main)을 한 줄씩 정리해 팀장에게 보임
5. 서버 시작 확인: `backend/api/server.py`는 시작 때 `check_startup()`으로 LLM 제공자를 검사한다. Cloud Run에서 `cli`면 시작을 막고, 제공자를 안 정하면 `fake` → 상세 분석은 "준비 중"으로 답함(합성 리포트를 주지 않음)

## 2. 시크릿 (팀장, 처음 한 번)

- DeepSeek 키를 Secret Manager에 넣는다. **키를 명령줄·대화·저장소에 붙이지 않는다** → 콘솔에서 만드는 것을 권장
  - 콘솔: Secret Manager → 시크릿 만들기 → 이름 `deepseek-api-key` → 값 붙여넣기
  - 서비스 계정 권한: `gwittim-api@gwittim-dev.iam.gserviceaccount.com`에 이 시크릿의 `Secret Manager 보안 비밀 접근자` 역할
- 권장: 수집 토큰도 같은 방식으로 `ingest-token` 시크릿으로 옮기고 일반 환경변수에서 뺀다(지금은 서비스 설정을 볼 수 있는 사람에게 값이 보임)

## 3. 서버 배포 (팀장 요청 시)

두 단계로 나눠 올리는 것을 권장한다. 문제가 생기면 어느 쪽인지 바로 안다.

```
# 3-1. 코드만 (상세 분석은 '준비 중'으로 답함)
gcloud run deploy gwittim-api --source . --project=gwittim-dev --region=asia-northeast3

# 3-2. DeepSeek 켜기 (코드 다시 빌드 없이 설정만 바꿔 새 리비전)
gcloud run services update gwittim-api --project=gwittim-dev --region=asia-northeast3 \
  --update-env-vars=GWITTIM_LLM_PROVIDER=deepseek,GWITTIM_LLM_MONTHLY_CAP_KRW=30000 \
  --update-secrets=DEEPSEEK_API_KEY=deepseek-api-key:latest
```

- 수집 토큰을 시크릿으로 옮겼다면 3-2에 `--update-secrets=GWITTIM_INGEST_TOKEN=ingest-token:latest`를 더하고, 일반 환경변수는 `--remove-env-vars=GWITTIM_INGEST_TOKEN`으로 뺀다(같은 이름을 둘 다 둘 수 없음)
- 기존 설정(최소 0·최대 2 인스턴스, 1 vCPU·512 MiB, 서비스 계정, 공개 호출)은 유지된다

## 4. 배포 후 확인

| 순서 | 확인 | 기대 |
|---|---|---|
| 1 | 토큰 없이 `/v1/recommendations` | 401 |
| 2 | 앱(dev API 빌드)으로 로그인 → 홈 | 추천 표시, 학교 안 고르면 "학교를 고르면 학교 공지도 볼 수 있습니다." |
| 3 | 프로필 학교 선택 | 선택 안 함 / 명지 / 숭의 / 목록에 없는 학교 |
| 4 | 크레딧 페이지 | 잔액 5(첫 가입) |
| 5 | 3-1 직후 상세 분석 | "분석 실패, 크레딧 차감 안 됨"(준비 중) |
| 6 | 3-2 뒤 상세 분석 1건 | 리포트 4칸, 동의 화면(받는 곳 DeepSeek) 먼저, 크레딧 5→4 |
| 7 | 로그 `gcloud run services logs read gwittim-api --project=gwittim-dev --region=asia-northeast3 --limit=50` | `llm requested_at=… provider=deepseek … cost_krw=…`, 오류 없음, 프롬프트 원문 없음 |
| 8 | Firestore `ops/llm_spend_2026-11` | 비용이 쌓임 |

## 5. 되돌리기

```
gcloud run services update-traffic gwittim-api --project=gwittim-dev --region=asia-northeast3 --to-revisions=<이전 리비전>=100
```

- 지금 되돌릴 곳(2026-11-24 00016 배포 기준): 설정만 되돌리면 `gwittim-api-00015-9zv`(같은 코드, 시연용 채우기 꺼짐·상한 3만 원), 코드까지 되돌리면 `gwittim-api-00014-shg`. Artifact Registry는 최근 이미지 2개만 남기므로 그보다 오래된 리비전은 되돌릴 수 없다

## 6. APK 빌드 (Claude가 함, 배포는 팀장이 공유)

1. 버전: `apps/mobile/pubspec.yaml`의 `version`
   - 개발 빌드: `0.10.x+N`(주마다 x 올림, N은 항상 올림)
   - 2차 제출 빌드: `1.0.0+N`
2. 빌드(dev API)
   ```
   cd apps/mobile
   flutter build apk --release --dart-define=GWITTIM_API_BASE=https://gwittim-api-630835219636.asia-northeast3.run.app
   ```
   - `android/app/google-services.json`이 있어야 함(git 제외, 작업 폴더에는 메인 폴더에서 복사)
   - 서명은 이 PC의 디버그 키(Firebase에 SHA-1 등록됨). 다른 PC에서 빌드하면 Google 로그인이 안 됨
   - 시연용 빌드: `--dart-define=GWITTIM_DEMO=true`를 더하면 크레딧 페이지에 '시연용 크레딧 채우기'가 생긴다. 서버도 `GWITTIM_DEMO_CREDITS=1`이어야 동작(아니면 '이 서버는 시연용 채우기를 켜지 않았습니다.'). 서버 설정은 시연 기간에만 켜고 끝나면 끈다. 켜 두어도 월 비용 상한은 그대로
3. 결과 `build/app/outputs/flutter-apk/app-release.apk` → `data/local/apk/gwittim-<main 커밋 7자리>.apk`로 복사, SHA-256 기록
4. 설치 확인: `adb install -r --user 0 <apk>` → §4의 2~6번을 실기기에서
5. 서버보다 앱이 먼저 나가면 새 화면이 옛 서버와 안 맞는다. **서버 배포 → APK 빌드** 순서

## 7. 정기 배치

- 수집기·분석 코드가 바뀐 PR을 병합하면 `Gwittim-batch`를 main으로 맞춘다(`git fetch` → `git checkout --detach origin/main` → `uv sync --frozen`)
- 다음 배치의 완료 알림과 `data/local/batch.log`로 확인

## 8. 비용 확인

- DeepSeek: 선불 잔액(플랫폼 화면), 서버 월 상한 1,400원(약 1달러, `GWITTIM_LLM_MONTHLY_CAP_KRW`, 2026-11-24 잔액 2달러라 3만 원에서 낮춤)
- GCP: 예산 알림 월 1,000원(알림일 뿐 상한 아님). Cloud Build·Artifact Registry 사용량은 배포 횟수만큼 늘어남

## 9. 배포 기록

| 날짜 | 리비전 | main | 바뀐 것 | 확인 |
|---|---|---|---|---|
| 2026-11-15 | gwittim-api-00007-nxm | 075a4ff | 수집 토큰 경로 | 401·토큰 확인 |
| 2026-11-23 | gwittim-api-00008-gcr | 4e906ce | §3-1 코드만(에이전트·크레딧·학교 규칙 rank-0.8·숭의 사전·rule-0.9). LLM 제공자 미설정 → 상세 분석 '준비 중'. 수집 토큰은 일반 환경변수 그대로 | 토큰 없이 recommendations·credits·profile·analysis·ingest 401, /docs 404, 시작 로그 정상, ERROR 0 |
| 2026-11-23 | gwittim-api-00009-fls | 4e906ce | §3-2 DeepSeek 켬: `GWITTIM_LLM_PROVIDER=deepseek`, 월 상한 30000, `DEEPSEEK_API_KEY`=시크릿 `deepseek-api-key:latest` | 새 리비전 정상 시작(시크릿 읽기 포함), 토큰 없이 401. 상세 분석 실호출은 APK 0.10.0으로 확인 예정 |
| 2026-11-23 | gwittim-api-00010-gw4 | f41eaf3 | 리포트 짧은 줄·꼬리표 지시문과 긴 문단 나누기(#140), 지침 harness 파일·저장본 키/로그에 지침 버전(#141), 서버 INFO 로그 설정 | 토큰 없이 401, 시작 로그 정상, ERROR 0. 환경변수·시크릿 유지 |
| 2026-11-23 | gwittim-api-00011-jbk | a5a5380 | 첫 카드 '나와 이 공고' 지침·판정 낱말 미충족(#142), 졸업 예정자 직접 확인 rule-0.10(#143, 서버 동작 영향 없음·배치에서 반영), 역량 원문 근거·마감 지남 할 일 후처리(#144), 지침 `detail-2026-11-23.5`. 배포 전 pytest 592·계약 검사·flutter analyze/test 276 통과. APK `0.10.2+5`(`data/local/apk/gwittim-0.10.2-a5a5380.apk`, SHA-256 `332cc309…99b0`, 서명 0.10.1과 같음) | 토큰 없이 recommendations·credits·profile·analysis 401, 시작 로그 정상, 새 리비전 ERROR 0. 환경변수·시크릿 유지. 실기기 설치·상세 분석은 미확인(폰 미연결) |
| 2026-11-23 | gwittim-api-00012-kls | d02e544 | 외부 공고 찾기 서버 `POST /v1/external-search`(DeepSeek 웹 검색·출처 검증, '출처 확인 안 됨' 표시, 크레딧 2개, #145, D-047)와 앱 화면(#146). 배포 전 pytest 611·계약 검사·flutter analyze/test 295 통과. APK `0.10.3+6`(`data/local/apk/gwittim-0.10.3-d02e544.apk`, SHA-256 `b35f9dca…14f7`, 서명 같음) | 토큰 없이 recommendations·credits·profile·analysis·external-search 401, 새 리비전 ERROR 0, 환경변수·시크릿 유지. 실기기 설치·외부 공고 찾기 실사용 미확인(폰 미연결) |
| 2026-11-23 | gwittim-api-00013-fft | 302d582 | 외부 공고 찾기 원문 읽고 자격 판정(2단계 호출 deepseek_read_url → evaluate, 미충족 제외), 고르는 칩 글자 폭, 외부 찾기 분류 9개(#147). 배포 전 pytest 620·계약 검사·flutter analyze/test 296 통과. APK `0.10.4+7`(`data/local/apk/gwittim-0.10.4-302d582.apk`, SHA-256 `51bee833…9c6f`, 서명 같음) | 토큰 없이 recommendations·credits·analysis·external-search 401, 새 리비전 ERROR 0, 환경변수·시크릿 유지 |
| 2026-11-23 | gwittim-api-00014-shg | 423faf0 | 외부 공고 찾기 지침 `external-2026-11-23.5`: 지금 접수 중인 공고 위주, 후보 8개까지(#148). #149(교외 중복 묶기)는 배치 코드라 서버 동작 변화 없음. 앱 변경 없음(APK 0.10.4 그대로). 배포 전 pytest 623·계약 검사 통과 | 토큰 없이 recommendations·credits·analysis·external-search 401, 새 리비전 ERROR 0, 환경변수·시크릿 유지 |
| 2026-11-24 | gwittim-api-00015-9zv | 290d3a1 | 신청 완료까지 챙기기(#157, 앱만), 리포트 내 지원 카드 진행 단계·교외 공고 '원문' 문구·시연용 크레딧 채우기 `POST /v1/credits/demo-refill`(#159, 계약 credits 내역 `demo` 추가). 배포 전 pytest 626·계약 검사·flutter analyze/test 446 통과. `gcloud run deploy --source`는 빌드 성공 뒤 `NOT_FOUND`로 끊겨 빌드 이미지(digest `1e2b6495…7f1`)를 `--image`로 배포. 앱 `0.10.5+8`(`data/local/apk/gwittim-0.10.5-3310e44.apk`, SHA-256 `5773bd47…189f`, 서명 같음, 폰 설치·실행 확인) | 토큰 없이 recommendations·credits·demo-refill·analysis·external-search 401, 시작 로그 정상, ERROR 0. 환경변수·시크릿 유지 |
| 2026-11-24 | gwittim-api-00016-5sp | 290d3a1 | 설정만: `GWITTIM_DEMO_CREDITS=1`(시연용 채우기 켬), `GWITTIM_LLM_MONTHLY_CAP_KRW=1400`(3만 원에서 낮춤, 배포 전 11월 누적 9.06원 확인). 시연용 APK `0.10.6+9`(`--dart-define=GWITTIM_DEMO=true`, `data/local/apk/gwittim-0.10.6-demo-290d3a1.apk`, SHA-256 `5df13ab6…39ef`, 서명 같음) | 설정 값 확인. 폰(0.10.6)에서 채우기 0→5, 상세 분석 1건 성공(5→4, DeepSeek 2.48초·0.77원, 11월 누적 9.83원). 시연이 끝나면 `GWITTIM_DEMO_CREDITS=0` |
