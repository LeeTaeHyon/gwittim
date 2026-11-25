# 귀띔 에이전트 인수인계 (검증본)

- 기준 시점: 2026-11-24 19:34 KST. 기준 커밋: origin/main `3310e44`(#157 병합)
- 갱신: 2026-11-25 13:45 KST. §1 상태 표와 아래 "11/25 바뀐 것"은 이 시각에 다시 조회한 값(origin/main `ed0778e`). §2 이후의 대조·검증 표는 11/24 조회값 그대로다
- 저장소 파일 경로와 줄 번호는 origin/main `3310e44` 기준이다. 메인 체크아웃은 뒤처져 있어 줄 번호가 다를 수 있다
- 이 문서는 직접 조회한 결과만 적는다. `docs/handoff.md`와 메모리 요약은 근거로 쓰지 않고 대조 대상으로만 썼다
- 작업 중에도 다른 세션이 계속 병합했다(조사 시작 때 `152292f` → 19:28에 `3310e44`, #158이 열림). 이 문서를 읽는 시점에는 숫자가 달라졌을 수 있다. 쓰기 전에 아래 "다시 확인하는 명령"부터 돌린다
- 표기
  - `~mybaton/` = `C:/Users/dlxog/.mybaton/worktrees/Gwittim-91d26c74/`
  - `.claude/worktrees/` = `C:/Users/dlxog/Desktop/all/Code_Project/Gwittim/.claude/worktrees/`
  - 시각: GitHub·gcloud 원문은 UTC이고, 본문은 KST(UTC+9)로 적는다

## 11/25 바뀐 것 (직접 조회)

- 병합(11/24 밤~11/25): #163 게스트 로그인(D-054), #104 공고 분석 자체 모델(D-042), #165 자체 모델 되돌림, #164 배포 기록 00017, #162 처리방침 구글 문서 초안, #153 고르는 칩 크기, #158 브리핑 범위 명세
- 공고 분석 자체 모델(D-042): **적용 보류, main에서 제거**
  - 11/25 00:09 #104 병합 → 00:10~00:59 정기 배치로 실제 반영 → 원문에 적힌 마감이 사라지는 문제(59건 중 명시 마감 16건)로 01:03 되돌림
  - 되돌린 뒤 로컬 공고·Firestore 공개본 모두 반영 전과 같음
  - #165(`5cc03e1`)가 #104를 되돌리고 시도 기록을 `legacy/extract-model/`에 보관(코드·시험·문서·README). `decisions.md` D-042는 "보류·되돌림"으로 남음
  - 운영 규칙 버전은 `rule-0.10` 그대로
- 상세 분석 본문 입력(#155, D-053): **11/25 닫음(보류, 미병합)**
  - 평가 합격선 미달. 브랜치 `feat/detail-body-input`(`b9a156b`)과 worktree `.claude/worktrees/detail-body`는 남김
  - 다시 살리면 #163과 4곳 충돌(`backend/agent/service.py`, `backend/firebase_store.py`, `docs/agent-privacy-spec.md`, `docs/decisions.md`). 양쪽 내용을 함께 살리면 풀림
  - 평가 도구(`tools/agent_eval_*`)와 D-053은 main에 없고 이 브랜치에만 있음
  - #162 처리방침 초안은 #155 반영본을 바탕으로 써서 '공고 본문' 문장이 있음. 게시할 때 빼야 함
- 메인 체크아웃: 11/25 origin/main과 같게 맞춤. 그 전 미커밋 문서 12개는 로컬 브랜치 `wip/local-docs-1125`(`13a6182`, 푸시 안 함)에 보관

## 0. 다시 확인하는 명령

```
git fetch origin; git log --oneline -3 origin/main
gh pr list --state open
gcloud run services describe gwittim-api --project=gwittim-dev --region=asia-northeast3 --format="value(status.traffic)"
git -C ../Gwittim-batch rev-parse --short HEAD
git worktree list | wc -l ; git branch | wc -l
```

## 1. 지금 상태 (재현 명령 → 실제 출력)

| 항목 | 명령 | 출력(2026-11-25 13:45 갱신) |
|---|---|---|
| main 최신 | `git log -1 origin/main` | `ed0778e` 11/25 07:19 "Merge pull request #158 from LeeTaeHyon/docs/briefing-spec" |
| 메인 체크아웃(`Gwittim` 폴더) | `git status`, `git rev-list --count main..origin/main` | 브랜치 `main` `ed0778e`, origin/main과 같음. 미커밋 0(11/24의 미커밋 문서는 로컬 브랜치 `wip/local-docs-1125`에 보관) |
| PR | `gh pr list --state all` | 전체 166건 = 병합 161, 열림 1, 닫힘 4(#37·#48·#79·#155) |
| 열린 PR | 〃 | #166 `docs/agent-handoff-docs`(이 문서) |
| Cloud Run 트래픽 | `gcloud run services describe gwittim-api ...` | `gwittim-api-00017-p8j` 100%. runbook 기록상 커밋 `175019e`(#163 게스트 로그인, `docs/deploy-runbook.md:113`) |
| 리비전 이력 | `gcloud run revisions list ...` | 00014 11/23 14:53, 00013 11/23 14:31, 00012 11/23 06:52, 00011 11/23 05:58, 00010 11/23 04:46, 00009 11/23 04:16, 00008 11/23 04:09, 00007 11/15 15:09 |
| 00014 ↔ 커밋 | `docs/deploy-runbook.md:108` | 00014 = `423faf0`. 리비전 메타데이터에는 커밋 정보가 없다(source zip 경로만 있음). 대응 관계는 runbook 기록으로만 확인 |
| 00014 환경변수 이름 | `gcloud run revisions describe ... --format=json` (이름만 읽음) | 일반 환경변수: `GWITTIM_FIREBASE_PROJECT_ID`, `GWITTIM_INGEST_TOKEN`, `GWITTIM_LLM_PROVIDER`, `GWITTIM_LLM_MONTHLY_CAP_KRW` / 시크릿: `DEEPSEEK_API_KEY`(`deepseek-api-key`) |
| 정기 배치 코드 | `git -C ../Gwittim-batch rev-parse --short HEAD` | `5cc03e1`(detached, #165 자체 모델 되돌림). 그 뒤 main 병합은 문서·앱뿐이라 배치 코드 차이 없음. 11/25 09:00 정기 배치 정상, 로컬 공고 637건 모두 자체 모델 분석 아님 |
| 예약 작업 | `Get-ScheduledTask`, `Get-ScheduledTaskInfo` | `Gwittim 수집 배치 (하루 2회)` Ready, 마지막 실행 11/24 18:00 결과 0, 다음 실행 11/25 09:00 |
| 마지막 배치 결과 | `data/local/batch.log` 188번째 줄 | 알림톡 단계 `collected 306, published 3, held_past 282, inbox 16`. 같은 실행에서 위비티 `listed 30·parsed 1`, 콘테스트코리아 `listed 24·parsed 10`, 카톡 내보내기 6개 방 ok |
| 최신 APK | `ls data/local/apk` | `data/local/apk/gwittim-0.10.4-302d582.apk`(60,974,876바이트, SHA-256 앞자리 `51bee8331d41`). `apps/mobile/pubspec.yaml` version은 `0.9.0+2`다(APK 이름과 다름) |
| Firebase | runbook, Cloud Run 조회 | 프로젝트 `gwittim-dev`, 리전 `asia-northeast3` |
| 로컬 도구 | `--version` | Flutter 3.47.7, uv 0.12.5, Ollama 0.40.17(`gemma4:12b` 8.0GB), Java 23.0.2, AVD `Medium_Phone`·`chzzk_pixel` |
| 공통 평가셋 | `data/local/eval_common/gold.csv` | 35행(명지 20 + 숭의 15). 숭의 초안 `data/local/sewu_score/sewu_gold_20b_초안.csv` 20행은 아직 합치지 않음 |
| SPEC | `head SPEC.md` | origin/main 0.20, 메인 체크아웃 파일은 0.19(뒤처진 체크아웃) |
| main 이력 재작성 | `git reflog show origin/main` | `2026-11-04 18:41 fetch origin: forced-update` 1회. 이유를 적은 기록은 찾지 못함(확인 불가) |

### 테스트 재실행 (origin/main을 `git archive`로 scratchpad에 풀어 실행)

| 검사 | 기준 | 결과 |
|---|---|---|
| `uv run pytest -q -p no:cacheprovider --basetemp=<scratch>` | `152292f`(그 뒤 `3310e44`까지 `backend/`·`contracts/`·`scripts/`·`tools/` 변경 없음) | **623 passed, 3 skipped**. `--basetemp` 없이 돌리면 `%TEMP%\pytest-of-dlxog` 권한 오류로 39 errors |
| `uv run python tools/validate_contracts.py` | `152292f` | schemas 16 OK, dictionaries 8 OK, stats 1 OK, valid fixtures 38 passed, invalid 51 rejected |
| `flutter analyze` / `flutter test` | `3310e44` | No issues / **441 passed, 2 skipped** |
| `npm test`(`tests/firestore-rules`, 에뮬레이터) | `152292f` | **7 pass, 0 fail**(포트 8095로 바꿔 실행. 아래 함정 참고) |
| 열린 PR 브랜치 테스트 | — | 미실행. 범위 밖 |

## 2. handoff와 다른 점 (주장-증거 표)

- 대상: origin/main `3310e44`의 `docs/handoff.md`. 메인 체크아웃 파일(11/23판)은 뒤처져 있다
- "현재 상태" 절(7~22줄)은 내용이 2026-10-18 무렵 그대로다

| # | handoff 주장(줄) | 확인 명령 | 실제 | 판정 |
|---|---|---|---|---|
| 1 | SPEC 0.2 (7) | `git show origin/main:SPEC.md \| head` | 0.20 | 불일치 |
| 2 | `uv run pytest` 87건 통과 (8) | pytest 재실행 | 623 passed, 3 skipped | 불일치 |
| 3 | 규칙 테스트 7건 통과 (9) | `npm test` | 7 pass | 일치 |
| 4 | Flutter 3.47.7, `flutter test` 17건 (10) | `flutter --version`, `flutter test` | 3.47.7 / 441 passed | 버전 일치, 건수 불일치 |
| 5 | Firebase·Cloud Run 미생성, 배포 없음 (11) | gcloud 조회 | `gwittim-dev`, 00014 서비스 중 | 불일치 |
| 6 | CI 없음 (11) | `git ls-tree origin/main .github` | 워크플로 없음, PR 템플릿만 있음 | 일치 |
| 7 | #7~#13 10-18 병합 (12) | `gh pr list` | 10-18 01:47~01:48 KST 병합 | 일치 |
| 8 | #18 미병합, 가장 먼저 병합하라 (13) | 〃 | 10-18 02:07 KST 병합됨 | 불일치 |
| 9 | #14~#17 열린 PR (14~20) | 〃 | 모두 10-18 02:07 KST 병합 | 불일치 |
| 10 | `unlisted` 학교 사전 (21) | `grep unlisted contracts/` | `contracts/dictionaries/universities.json:16` | 일치 |
| 11 | ui-style.md 규칙 (22) | `ls docs/ui-style.md` | 있음 | 일치 |
| 12 | 미결: 웹 빌드로 화면 확인 (541) | — | 10/18 일회성 기록 | 확인 불가 |
| 13 | 미결: Firebase·Cloud Run 생성 필요 (543) | gcloud | 이미 있음 | 불일치 |
| 14 | 미결: Ollama 미설치 (544) | `ollama list` | 0.40.17, gemma4:12b | 불일치 |
| 15 | 미결: AVD 없음 (545) | `emulator -list-avds` | `Medium_Phone`, `chzzk_pixel` | 불일치 |
| 16 | 미결: 사전 draft (546) | `grep status contracts/dictionaries/*.json` | 8개 모두 `"draft"` | 일치 |
| 17 | 미결: 대회 마감일 공식 공지 (548) | — | 원자료 없음 | 확인 불가 |
| 18 | 서버 00014 = `423faf0` (588) | gcloud + runbook:108 | 00014 100%, 커밋은 runbook 기록만 | 일치(커밋은 기록 기준) |
| 19 | APK 0.10.4+7 `data/local/apk/gwittim-0.10.4-302d582.apk` (588) | `ls data/local/apk/gwittim-0.10.4-302d582.apk` | 파일 있음, 해시 앞자리 `51bee833` = runbook:107 | 일치 |
| 20 | 배치 `../Gwittim-batch` = `423faf0` (588) | `git -C ../Gwittim-batch rev-parse` | `423faf0` | 일치 |
| 21 | 되돌릴 곳 00013 (590) | revisions list | 00013-fft 있음 | 일치 |
| 22 | 남은 것: 첫 카드·'출처 확인 안 됨' 폰 확인 (626) | — | 폰 기록 없음 | 확인 불가 |
| 23 | 남은 것: 외부 찾기에 자동 수집 공고 먼저 (627) | 11/23 이후 origin/main 커밋 제목 | 해당 커밋 없음 | 일치(아직 안 함) |
| 24 | 남은 것: 폰에서 탈퇴 팝업·큰 글자 확인 (628) | — | 폰 기록 없음 | 확인 불가 |
| 25 | 남은 것: 숭의 초안 20건 확인 → 55건 (629) | `data/local/eval_common/gold.csv` 행 수 | 35행, 초안 20행 따로 있음 | 일치(아직 안 함) |
| 26 | 남은 것: "커밋 안 된 문서" `docs/final-prep-todo.md`, `docs/stage2-results.md` (630) | `git ls-files`, `git status` | 둘 다 이미 추적 중(`152bb86`)이고 **수정분만** 미커밋. 메인 체크아웃 사본과 `~mybaton/d84cdf7e0041-1` 사본이 서로 다름(83·115줄부터) | 불일치(표현). 미커밋 수정은 사실 |
| 27 | care-loop "푸시·PR 전" (646) | `gh pr view 157` | 11/24 19:27 KST #157로 병합 | 불일치(작성 직후 병합) |
| 28 | care-loop `flutter test` 441 통과·2 건너뜀 (653) | flutter test `3310e44` | 441 passed, 2 skipped | 일치 |
| 29 | care-loop 남은 것: 실제 폰 확인 전 (659) | — | 폰 기록 없음 | 확인 불가 |

- 집계: 일치 13 / 불일치 12 / 확인 불가 5. #4는 버전 일치·건수 불일치라 양쪽에 1씩 셌다(합 30)
- handoff 밖에서 찾은 어긋남
  - `docs/decisions.md`(origin/main)에 `## D-051` 제목이 없다(D-050 다음이 D-052). 본문 언급은 1회
  - handoff "1주차 UI" 절과 `apps/mobile/lib/ui/app_info.dart`: 앱 '버전' 줄은 0.9.0이다(pubspec `0.9.0+2`). 실제 설치 APK 이름은 0.10.4

## 3. 떠 있는 작업 전수 분류

- 분류 규칙
  - 병합됨: origin/main의 조상
  - 병합됨(내용): 조상은 아니지만 `git cherry origin/main <브랜치>`의 `+`가 0개. 대부분 11/04 이력 재작성 전 브랜치다(GitHub의 PR 병합 커밋 해시와 main 해시가 다름, 트리는 같음. 예: #75 병합 `4124734` vs main `fd5db5f`, `git diff` 빈 결과)
  - PR 열림 / 푸시 전 / 중단 / 용도 불명
- 집계: 로컬 브랜치 153 = 병합됨 66 + 병합됨(내용) 78 + PR 열림 4 + 푸시 전 4 + 중단 1. worktree 69개(메인 체크아웃·`../Gwittim-batch` 포함). 미분류 0

### 3.1 병합 안 된 브랜치

- PR 열림
  - `feat/extract-model` `e4de4de` #104
  - `feat/analysis-chips` `234cfcd` #153
  - `feat/detail-body-input` `2895bf7` #155
  - `docs/briefing-spec` `534a708` #158
  - 네 브랜치 모두 원격과 같은 커밋
- 푸시 전(로컬만, 원격·PR 없음)
  - `mybaton/57499b6156ed-3`·`-4` `649ef71`, `mybaton/d84cdf7e0041-1`·`-2` `4cb263b`
  - 커밋 제목은 모두 "mybaton: 병렬 작업 시작점"
  - 내용은 그때 메인 체크아웃의 미커밋 문서 사본이다(`docs/final-prep-todo.md`, `docs/stage2-results.md`, 649ef71은 `docs/agent-quality-eval-spec.md`까지)
- 중단
  - `feat/ui-polish` `db08665`(10/28)
  - 원격보다 5커밋 앞서 있고, main에 없는 패치 1개 `74d1821` "로그인 화면 예시 말풍선이 하나씩 도착하게"
  - #38은 이 브랜치의 앞 커밋으로 병합됨
- 원격보다 앞서 있지만 내용은 main에 있음
  - `feat/home-single-list` `b80b0b2`: origin 브랜치보다 1커밋 앞. #157 경로로 main에 들어감(cherry 0)
  - `feat/report-skills-todo`: 3커밋 앞, main 조상

### 3.2 미커밋 변경이 있는 worktree (11곳 + 찌꺼기 4곳)

| worktree | 브랜치 | 미커밋 내용 | 분류 |
|---|---|---|---|
| `../Gwittim`(메인) | `main` | 위 5개 파일. `docs/agent-detail-body-spec.md`·`docs/agent-quality-eval-spec.md`는 `origin/feat/detail-body-input`의 같은 파일과 바이트가 같음. `docs/notice-detail-poster-spec.md`는 어느 브랜치에도 없고 `.claude/worktrees/notice-poster` 사본과도 다름 | 푸시 전(문서) |
| `~mybaton/57499b6156ed-4` | `mybaton/57499b6156ed-4` | 새 파일 15개. **`~mybaton/57499b6156ed-4/docs/agent-quality-eval.md`(지침 평가 결과)는 어느 브랜치에도 없음**. `tools/agent_eval_*.py` 대부분은 `origin/feat/detail-body-input`과 같음(`~mybaton/57499b6156ed-4/tools/agent_eval_detail.py` 제외) | 푸시 전(유일본 있음) |
| `~mybaton/d84cdf7e0041-1` | `feat/home-single-list` | `~mybaton/d84cdf7e0041-1/docs/final-prep-todo.md`, `~mybaton/d84cdf7e0041-1/docs/stage2-results.md` 수정(메인 사본과 다름) | 용도 불명 |
| `~mybaton/d84cdf7e0041-2` | `mybaton/d84cdf7e0041-2` | 7개. `~mybaton/d84cdf7e0041-2/docs/care-loop-spec.md`·`~mybaton/d84cdf7e0041-2/docs/deadline-fix-spec.md`·`~mybaton/d84cdf7e0041-2/docs/todo-grounding-spec.md`·`~mybaton/d84cdf7e0041-2/SPEC.md`는 main과 같음. 같은 폴더의 `docs/decisions.md`·`docs/handoff.md`·`~mybaton/d84cdf7e0041-2/docs/care-loop-impl-spec.md`는 main과 다름 | 중단(main에 들어간 명세의 초안) |
| `.claude/worktrees/home-tidy` | `feat/home-tidy` | 앱 코드·테스트 10개와 `docs/decisions.md`(D-049 초안)·`docs/ui-style.md` 수정, +463/−266 | 용도 불명 |
| `.claude/worktrees/combo-build` | detached `1685e7a`(재작성 전) | 앱 11개 파일 수정, +257/−20, 파일 시각 11/04 | 용도 불명 |
| `.claude/worktrees/explore-stats-recommend-f7bc4a` | `claude/explore-stats-recommend-f7bc4a` | `.claude/worktrees/explore-stats-recommend-f7bc4a/experiments/major_prior/` 등 추적 안 된 15개(학과 통계 실험 원본) | 중단 |
| `.claude/worktrees/kakao-gui` | `feat/kakao-refresh-gui` | `docs/handoff.md` 수정, `.claude/worktrees/kakao-gui/tools/kakao_refresh_gui.py`·`.claude/worktrees/kakao-gui/scripts/kakao_refresh.cmd` 새 파일(11/03) | 용도 불명 |
| `.claude/worktrees/opencode-go` | `feat/llm-opencode-go` | `.claude/worktrees/opencode-go/backend/agent/llm.py` +136/−36(`opencode` 제공자). main의 `backend/agent/llm.py`에는 opencode가 없고, opencode 호출은 `tools/harness_check.py` 등 도구 쪽에 있음 | 용도 불명 |
| `.claude/worktrees/notice-poster` | `feat/notice-poster` | `docs/notice-detail-poster-spec.md` 새 파일 | 푸시 전(문서) |
| `.claude/worktrees/detail-body` | `feat/detail-body-input` | 조사 중 다른 세션이 편집함(`docs/legal/privacy.md` 수정, `.claude/worktrees/detail-body/docs/legal/privacy-gdoc-draft.md` 새 파일) | PR 열림(작업 중) |
| `agent-ada28acf72a163219`, `report-first-card`, `report-skills-todo`, `grad-expected` | — | pytest-of-dlxog 폴더만 | 찌꺼기 |

### 3.3 worktree 전체 표

| worktree | 브랜치/HEAD | 분류 | 미커밋 파일 |
|---|---|---|---|
| `../Gwittim` | `main` | 병합됨 | 5 |
| `~mybaton/57499b6156ed-3` | `mybaton/57499b6156ed-3` | 푸시 전 |  |
| `~mybaton/57499b6156ed-4` | `mybaton/57499b6156ed-4` | 푸시 전 | 15 |
| `~mybaton/d84cdf7e0041-1` | `feat/home-single-list` | 병합됨(내용) | 2 |
| `~mybaton/d84cdf7e0041-2` | `mybaton/d84cdf7e0041-2` | 푸시 전 | 7 |
| `.claude/worktrees/agent-ada28acf72a163219` | `feat/kakao-phone-preview` | 병합됨 |  (+pytest-of 찌꺼기) |
| `.claude/worktrees/agent-harness` | `feat/agent-harness` | 병합됨 |  |
| `.claude/worktrees/analysis-chips` | `feat/analysis-chips` | PR 열림 |  |
| `.claude/worktrees/batch-ext` | `feat/batch-external` | 병합됨 |  |
| `.claude/worktrees/briefing-spec` | `docs/briefing-spec` | PR 열림 |  |
| `.claude/worktrees/build-main` | `docs/deploy-1030` | 병합됨(내용) |  |
| `.claude/worktrees/care-loop` | `feat/care-loop` | 병합됨 |  |
| `.claude/worktrees/category-human-cv` | `feat/error-case-experiments` | 병합됨 |  |
| `.claude/worktrees/collector-fix` | `(detached e01c1fe)` | 병합됨 |  |
| `.claude/worktrees/combo-build` | `(detached 1685e7a)` | 병합됨(내용) | 11 |
| `.claude/worktrees/common-analysis-rules` | `feat/common-analysis-rules` | 병합됨 |  |
| `.claude/worktrees/deploy-147` | `(detached 302d582)` | 병합됨 |  |
| `.claude/worktrees/deploy-423faf0` | `(detached 423faf0)` | 병합됨 |  |
| `.claude/worktrees/deploy-a5a5380` | `(detached a5a5380)` | 병합됨 |  |
| `.claude/worktrees/deploy-d02e544` | `(detached d02e544)` | 병합됨 |  |
| `.claude/worktrees/detail-body` | `feat/detail-body-input` | PR 열림 | 1 |
| `.claude/worktrees/docs-runbook` | `docs/deploy-runbook` | 병합됨 |  |
| `.claude/worktrees/eval-common` | `feat/eval-common` | 병합됨 |  |
| `.claude/worktrees/explore-stats-recommend-f7bc4a` | `claude/explore-stats-recommend-f7bc4a` | 병합됨(내용) | 15 |
| `.claude/worktrees/external-dedup` | `feat/external-dedup` | 병합됨 |  |
| `.claude/worktrees/external-search` | `feat/external-search` | 병합됨 |  |
| `.claude/worktrees/external-search-app` | `feat/external-search-app` | 병합됨 |  |
| `.claude/worktrees/external-search-fix` | `fix/external-search-ui` | 병합됨 |  |
| `.claude/worktrees/external-search-open` | `fix/external-search-open` | 병합됨 |  |
| `.claude/worktrees/extract-model` | `feat/extract-model` | PR 열림 |  |
| `.claude/worktrees/first-login-profile` | `feat/first-login-profile` | 병합됨(내용) |  |
| `.claude/worktrees/fix-local-publication` | `feat/fix-local-publication` | 병합됨 |  |
| `.claude/worktrees/grad-expected` | `fix/graduation-expected` | 병합됨 |  (+pytest-of 찌꺼기) |
| `.claude/worktrees/handoff-1122` | `docs/handoff-1122` | 병합됨 |  |
| `.claude/worktrees/handoff-1123` | `docs/handoff-1123` | 병합됨 |  |
| `.claude/worktrees/happy-zhukovsky-259150` | `(detached 75e3c76)` | 병합됨(내용) |  |
| `.claude/worktrees/home-tidy` | `feat/home-tidy` | 병합됨 | 14 |
| `.claude/worktrees/integrate` | `feat/integrate-p0` | 병합됨(내용) |  |
| `.claude/worktrees/kakao-auto-export` | `feat/kakao-export-autostart` | 병합됨 |  |
| `.claude/worktrees/kakao-card` | `feat/kakao-card-copy` | 병합됨(내용) |  |
| `.claude/worktrees/kakao-gui` | `feat/kakao-refresh-gui` | 병합됨(내용) | 3 |
| `.claude/worktrees/kakao-inbox-upload` | `(detached 075a4ff)` | 병합됨 |  |
| `.claude/worktrees/kakao-notices` | `feat/kakao-notices` | 병합됨(내용) |  |
| `.claude/worktrees/llm-deepseek` | `feat/llm-deepseek` | 병합됨 |  |
| `.claude/worktrees/major-feedback` | `feat/major-prior-feedback` | 병합됨(내용) |  |
| `.claude/worktrees/major-prior` | `feat/major-prior` | 병합됨(내용) |  |
| `.claude/worktrees/mobile-sample-refresh` | `feat/mobile-sample-refresh` | 병합됨 |  |
| `.claude/worktrees/notice-poster` | `feat/notice-poster` | 병합됨 | 1 |
| `.claude/worktrees/notif-probe` | `feat/ondevice-kakao-filter` | 병합됨 |  |
| `.claude/worktrees/null-school` | `feat/null-school-external-only` | 병합됨 |  |
| `.claude/worktrees/ondevice-classifier` | `feat/ondevice-classifier` | 병합됨 |  |
| `.claude/worktrees/opencode-go` | `feat/llm-opencode-go` | 병합됨 | 1 |
| `.claude/worktrees/past-sync` | `fix/kakao-past-resync` | 병합됨 |  |
| `.claude/worktrees/report-first-card` | `feat/report-first-card` | 병합됨 |  (+pytest-of 찌꺼기) |
| `.claude/worktrees/report-readability` | `feat/report-readability` | 병합됨 |  |
| `.claude/worktrees/report-skills-todo` | `feat/report-skills-todo` | 병합됨 |  (+pytest-of 찌꺼기) |
| `.claude/worktrees/resume-refresh` | `fix/resume-refresh` | 병합됨(내용) |  |
| `.claude/worktrees/sample-label` | `feat/sample-mode-label` | 병합됨(내용) |  |
| `.claude/worktrees/school-terms-check` | `feat/school-terms-check` | 병합됨 |  |
| `.claude/worktrees/sewu-app` | `feat/sewu-app` | 병합됨 |  |
| `.claude/worktrees/sewu-batch` | `feat/sewu-batch` | 병합됨 |  |
| `.claude/worktrees/sewu-collector` | `feat/sewu-collector` | 병합됨 |  |
| `.claude/worktrees/sewu-contract` | `feat/sewu-contract` | 병합됨 |  |
| `.claude/worktrees/token-refresh` | `fix/token-refresh` | 병합됨(내용) |  |
| `.claude/worktrees/ui-week1` | `feat/ui-week1` | 병합됨 |  |
| `.claude/worktrees/unlisted` | `feat/unlisted-school` | 병합됨 |  |
| `.claude/worktrees/verified-touch` | `docs/weekend-batch` | 병합됨 |  |
| `.claude/worktrees/vigorous-swanson-93f3a0` | `(detached 8a3fe14)` | 병합됨(내용) |  |
| `../Gwittim-batch` | `(detached 423faf0)` | 병합됨 |  |

### 3.4 로컬 브랜치 전체

**PR 열림 (4)**

- `docs/briefing-spec` `534a708` 2026-11-24 원격 있음 PR #158O=
- `feat/analysis-chips` `234cfcd` 2026-11-23 원격 있음 PR #153O=
- `feat/detail-body-input` `2895bf7` 2026-11-24 원격 있음 PR #155O=
- `feat/extract-model` `e4de4de` 2026-11-18 원격 있음 PR #104O=

**푸시 전 (4)**

- `mybaton/57499b6156ed-3` `649ef71` 2026-11-23 로컬만 PR 없음
- `mybaton/57499b6156ed-4` `649ef71` 2026-11-23 로컬만 PR 없음
- `mybaton/d84cdf7e0041-1` `4cb263b` 2026-11-23 로컬만 PR 없음
- `mybaton/d84cdf7e0041-2` `4cb263b` 2026-11-23 로컬만 PR 없음

**중단 (1)**

- `feat/ui-polish` `db08665` 2026-10-28 원격 있음 PR #38M≠

**병합됨(내용) (78)**

`claude/explore-stats-recommend-f7bc4a`, `claude/happy-zhukovsky-259150`, `claude/vigorous-swanson-93f3a0`, `docs/batch-schedule`, `docs/deploy-1030`, `docs/deploy-1101`, `docs/development-preparation-spec`, `docs/finalize-decisions`, `docs/firebase-dev-setup`, `docs/m1-work-items`, `docs/progress-2026-10-18`, `docs/progress-2026-10-18b`, `docs/readme-1103`, `docs/ui-dark-screens`, `docs/ui-polish-spec`, `docs/ui-style`, `feat/app-icon`, `feat/app-info`, `feat/app-shared-recs`, `feat/batch-visibility`, `feat/calendar`, `feat/capsule-tab`, `feat/checklist-cleanup`, `feat/checklist-grouping`, `feat/contracts-v1`, `feat/copy-tone`, `feat/first-login-profile`, `feat/home-feedback`, `feat/home-single-list`, `feat/image-alt-text`, `feat/integrate-1101`, `feat/integrate-p0`, `feat/intro`, `feat/kakao-card-copy`, `feat/kakao-dedup-link`, `feat/kakao-notices`, `feat/kakao-refresh-gui`, `feat/logo-in-app`, `feat/m1-batch-e2e`, `feat/major-prior`, `feat/major-prior-feedback`, `feat/more-boards`, `feat/notices-category-chips`, `feat/profile-picker`, `feat/rank-dated-first`, `feat/rule-tags`, `feat/sample-dates-today`, `feat/sample-mode-label`, `feat/trial-terms`, `feat/ui-v2`, `feat/w1-collect-pipeline`, `feat/w12-recommendation`, `feat/w13-api`, `feat/w14-profile-saved`, `feat/w2-mjc-adapter`, `feat/w3-analysis`, `feat/w4-publish`, `feat/w5-mobile-app`, `feat/w6-app-api`, `feat/w6-app-google-signin`, `feat/w6-firebase-server`, `feat/w8-llm-analyzer`, `feat/w9-ops-values`, `fix/chip-no-reflow`, `fix/chips-on-refresh`, `fix/demo-scene-title`, `fix/eligibility-filter`, `fix/gitignore-lib-data`, `fix/keepall-missing`, `fix/korean-line-break`, `fix/profile-step-motion`, `fix/refresh-error`, `fix/resume-refresh`, `fix/signin-silent-fail`, `fix/tab-route-motion`, `fix/token-refresh`, `fix/work-period-deadline`, `local/device-check`

**병합됨 (66)**

`docs/agent-spec`, `docs/agent-spec-search-input`, `docs/decisions-d038-d043`, `docs/deploy-runbook`, `docs/github-setup-handoff`, `docs/handoff-1122`, `docs/handoff-1123`, `docs/handoff-trial-apk`, `docs/privacy-agent-draft`, `docs/source-terms-review`, `docs/stage2-records`, `docs/weekend-batch`, `feat/agent-api`, `feat/agent-app`, `feat/agent-contracts`, `feat/agent-credits`, `feat/agent-harness`, `feat/agent-llm-provider`, `feat/agent-payload`, `feat/agent-report-cache`, `feat/batch-external`, `feat/care-loop`, `feat/category-human-cv`, `feat/common-analysis-rules`, `feat/error-case-experiments`, `feat/eval-common`, `feat/external-collector`, `feat/external-dedup`, `feat/external-search`, `feat/external-search-app`, `feat/fix-local-publication`, `feat/home-briefing-icons`, `feat/home-tidy`, `feat/kakao-auto-export`, `feat/kakao-export-autostart`, `feat/kakao-inbox-upload`, `feat/kakao-phone-preview`, `feat/llm-api-ready`, `feat/llm-deepseek`, `feat/llm-opencode-go`, `feat/mobile-sample-refresh`, `feat/notice-poster`, `feat/notif-probe`, `feat/null-school-external-only`, `feat/ondevice-classifier`, `feat/ondevice-kakao-filter`, `feat/profile-select-cap`, `feat/report-first-card`, `feat/report-readability`, `feat/report-skills-todo`, `feat/school-terms-check`, `feat/sewu-app`, `feat/sewu-batch`, `feat/sewu-collector`, `feat/sewu-contract`, `feat/similar-notices`, `feat/ui-week1`, `feat/unlisted-school`, `fix/collector-newest-message`, `fix/external-search-open`, `fix/external-search-ui`, `fix/graduation-expected`, `fix/kakao-past-resync`, `fix/last-verified-refresh`, `main`, `worktree-agent-ada28acf72a163219`

## 4. 실패한 시도 (해 보고 버린 것)

- 상세 분석 지침 평가(2026-11-24)
  - 근거: `~mybaton/57499b6156ed-4/docs/agent-quality-eval.md`(미커밋 유일본), `docs/agent-quality-eval-spec.md`
  - 표본: 공고 30건 × 프로필 3 = 방식마다 리포트 90개. 정답 재현 분모는 사람 정답 기준 약 393줄
  - 합격선: 어긋남 1% 이하, "공고에 없다" 오판 0건, 근거율 95% 이상, 정답 재현 70% 이상, 새 사실 2개 이상

  | 후보 | 내용 | 정답 재현 | 판정·버린 이유 |
  |---|---|---|---|
  | 지금 | — | 14.8%(58/393) | 기준선 |
  | D1 | 본문 입력 | 35.1%(138/393) | 불합격. 어긋남 1.6%, 오판 1건 |
  | D2 | D1 + 인용 대조 | 33.6%(130/387) | 불합격·버림. 거른 줄 0개, 원가 1.7배 |
  | D3 | D1 + 줄 수 상한 | 47.3% | 불합격. 근거율 94.98%(700/737). 팀장 결정으로 PR #155(D-053)에 반영했으나 11/25 PR 닫음(보류, 미병합) |
  | D4 | D3 + 역량 근거를 본문으로 | 46.6% | 불합격·"효과 없음"으로 버림(`docs/agent-detail-body-spec.md:25`) |
  | G | 일반 AI 비교군 | 62.8%(247/393) | G도 70% 미달 |
  | X2+L | 외부 찾기 변형 | 쓸 결과 요청당 1.75개(합격선 3) | 불합격. 12요청 중 과금됐는데 0개인 요청 2회 |

  - care-loop 8(b) 본문 입력 효과 시험(11/24, opencode 0원, 68건, `docs/care-loop-spec.md` §7 표, origin/main 기준 607~625줄)
    - 근거율 98%(62/63), 신청 경로 25/29로 좋아짐
    - 형식 위반(90자 넘는 줄) 13 → 27로 미달 → 8a만 진행하고 본문 입력은 미룸
    - 원자료: `data/local/care_loop/*_body_test.*`
- 알림톡 분류 모델(`docs/decisions.md`, 287건, 5겹 × 씨앗 5)
  - Gemma 라벨 학습(앱 배치) 종류 정확도 0.418 → 사람 정답 학습 0.782. McNemar p < 0.0001(1688·1693줄, D-035, 11/15). Gemma 라벨 학습은 버림
  - 캐스케이드(애매하면 Gemma): 관심사 F1 0.800 → 0.734로 떨어져 종류에 쓰지 않음(1746줄 근처)
  - 관심사 꼬리표별 문턱(D-037): 정확히 일치 0.841 → 0.843. 헛붙임 95 → 75로 줄었지만 놓침이 24 → 38로 늘었고, 검증 세트가 40건 남짓이라 안 씀(1832·1848줄)
- 공고 분석 자체 모델(D-042): 11/25 #104 병합·실제 반영 뒤 마감 누락으로 되돌리고 보류(#165, `legacy/extract-model/`). 아래는 11/24 조회값
  - `data/local/extract_distill/compare_out/report.json`: 자체 모델 마감 맞음 83, 기타 조건 80/111(72%)
  - 브랜치 기록의 84·82%를 담은 data 파일은 확인 불가
  - 기타 조건 LLM 필터 안은 재현율 85 → 81%로 떨어져 버림(브랜치 기록)
- 화면·로고
  - D-010 떠 있는 캡슐 탭: 앱에 넣어 본 뒤 버림. 꽉 채우면 촌스럽고 이름 폭이면 너무 작음(`docs/decisions.md:513`)
  - D-011 로고: 시안 B(형광펜)·C(귓속말)·세로로 긴 A안 대신 A1(`docs/decisions.md:542`)
- 그 밖
  - D-014 이미지 OCR(gemma4 비전) 보류. 포스터 1장 시험에서 요일·작은 글씨를 틀리고 없는 문장을 만들었고, 한 장에 18초(`docs/decisions.md:690`)
  - D-039 Gemma4:12b는 맞춤 리포트에서 제외. 공고 20건에서 구조 조건 정밀도 0.29
  - D-041 창에 키를 직접 보내는 방식(PostMessage) 안 씀(`docs/decisions.md:2108`)
  - D-044 Anthropic → DeepSeek. Anthropic 코드는 남겨 둠
  - D-047 출처 미확인 결과를 버리던 첫 구현을 되돌리고 표시를 붙여 보이게 함
  - 발표 영상 쇼릴 보류: 메모리 기록만 있음, 원자료 확인 불가

## 5. 권한 경계

- 묻지 않고 해도 됨
  - 읽기·조회: git·`gh pr list`·gcloud 조회·로그 읽기
  - 테스트 실행
  - 배포 전 점검(`docs/deploy-runbook.md:18` "Claude가 함")
  - APK 빌드(`docs/deploy-runbook.md:71`, 공유는 팀장)
  - 기술 세부는 추천안으로 정하고 기록(메모리 `decide-in-chat-claude-edits`)
- 팀장 지시가 있어야 함
  - 클라우드 리소스 생성·배포, 저장소 설정 변경: `AGENTS.md:20`, `docs/deploy-runbook.md:33` "서버 배포 (팀장 요청 시)"
  - main 직접 푸시 금지, 기능 브랜치 + PR: `AGENTS.md:21`. main 보호가 기술적으로 걸려 있지 않아 규칙으로만 막는다(`docs/decisions.md:144`)
  - 승인 안 된 라이브러리·유료 API·서비스 추가 금지: `AGENTS.md:18`
  - 파일 삭제·대규모 이동·포맷 일괄 변경: `AGENTS.md:19`
  - 공통 계약(SPEC·contracts·사전) 변경은 팀장 승인 뒤, 한 PR에서 함께: `AGENTS.md:25-30`
  - 커밋·PR·병합: 사용자가 말할 때만. 대화 원문
    - 11/23 `81a10e63…jsonl` "작업이 확정되면 진행하지말고 명세만 작성해줘"
    - 10/25 `7d9167be…jsonl` "PR에 굳이 넣지말고 변경점만 간략하게"
  - worktree 삭제: 지시 전 금지. 병합된 것도 남김(`b8b49d7b…jsonl` "혹시 모르니")
  - Gwittim-batch 갱신, 배치 손 실행, Firestore 반영: 매번 명시 지시로 했음(예: 10/26 `2c9d3430…jsonl` "PR #40 병합하고 API 재배포, Gwittim-batch 갱신까지")
- 비용
  - 시험용 LLM 호출은 opencode 구독 우선
  - DeepSeek API 잔액은 2달러로, 웹 검색에만 씀(`b8b49d7b…jsonl` "2달러만 충전돼있어서")
  - 서버 월 상한 3만 원(`GWITTIM_LLM_MONTHLY_CAP_KRW`)
- 문체
  - 커밋은 짧게. `Co-Authored-By: Claude`·"Generated with" 꼬리말 금지(10/20 "커밋 코멘트가 너무 AI틱함")
  - 앱 문구는 해요체 금지(D-020/D-022)
  - 사용자에게 하는 말은 한국어
- 학교 이용 허락은 팀장이 맡음. 다시 꺼내지 않는다(10/17 "학교 허락은 맡았다니까")

## 6. 환경 함정 (이 PC 전용)

- 메인 체크아웃은 공유 상태다
  - 지금 `main`이 25커밋 뒤이고 남의 미커밋 문서가 있다
  - 체크아웃·풀·stash 금지. 작업은 `.claude/worktrees/<이름>`에 새로 만든다
  - 조회만 할 때는 `git archive origin/main | tar -x -C <scratch>`
- 정기 배치
  - 코드: `C:/Users/dlxog/Desktop/all/Code_Project/Gwittim-batch`(detached worktree)
  - 데이터·로그: `Gwittim/data/local`, `data/local/batch.log`
  - 예약 작업 `Gwittim 수집 배치 (하루 2회)`가 `scripts/run_batch.ps1`을 부른다
  - 갱신: `git -C ../Gwittim-batch fetch origin` → `checkout --detach origin/main` → `uv sync`(지시 있을 때만)
- 다른 세션이 동시에 일한다
  - `~mybaton/` worktree는 mybaton 도구가 만든 병렬 세션 자리다
  - 조사 중에도 #157 병합·#158 생성이 일어났다
- pytest: `%TEMP%\pytest-of-dlxog` 권한 거부로 tmp_path 시험 39개가 error난다. `--basetemp=<쓸 수 있는 폴더>`와 `-p no:cacheprovider`를 붙인다
- 규칙 테스트: `npm test`가 8080 포트를 쓴다
  - 이번 조사 첫 실행이 Java 에뮬레이터(PID 57872, 19:31 시작)를 남겨 포트를 잡고 있다(아래 남은 문제)
  - `firebase.json` 사본의 포트를 바꾸면 돈다
  - 저장소 파일은 고치지 않는다
- 인코딩
  - Python 기본이 cp949라 한글 JSON·CSV 읽기가 깨진다 → `PYTHONUTF8=1` 또는 `encoding='utf-8'`
  - `scripts/run_batch.ps1`·`scripts/export_kakao.ps1`은 UTF-8 BOM + CRLF 유지(`docs/troubleshooting.md:55`)
- `.venv` 파이썬은 샌드박스에서 임시 폴더 쓰기가 막힘 → 단계를 나눠 실행(메모리 `reference-opencode-harness-run`, `docs/troubleshooting.md` 22·32·34줄)
- Windows 경로 길이: `git worktree remove`가 실패할 수 있음(`docs/troubleshooting.md:43`). 어차피 삭제는 지시 전 금지
- 앱 빌드
  - Firebase 앱 설정 파일은 worktree에 따라오지 않음 → 메인의 `apps/mobile/android/app/google-services.json` 복사(`docs/troubleshooting.md:44`)
  - APK 서명은 이 PC 디버그 키(다른 PC 빌드는 Google 로그인 실패, `docs/deploy-runbook.md:82`)
- 폰 측정: `flutter drive`는 끝나면 앱을 지움 → `--keep-app-running`(`docs/troubleshooting.md:63`). 설치는 `adb install -r --user 0`
- 에뮬레이터 실제 데이터 확인: `data/local/notices.json` 로컬 서버 + `10.0.2.2:8765`(메모리 `reference-real-data-emulator-check`)
- PDF 확인: pdftoppm 없음 → Chrome 헤드리스(`docs/troubleshooting.md:73`)
- gcloud는 이 PC에 로그인돼 있다(ADC). 조회는 되지만 배포·설정 변경은 지시 전 금지

## 7. 비밀값 위치 (값은 읽지 않음)

| 위치 | 용도 |
|---|---|
| `Gwittim/.env` | 로컬 환경변수 |
| `data/local/ingest_token.txt` | 폰 수집기 → `POST /v1/ingest/kakao` 토큰. 서버에는 일반 환경변수 `GWITTIM_INGEST_TOKEN`으로 들어가 있음 |
| `apps/mobile/android/app/google-services.json` | Firebase 앱 설정(커밋 금지) |
| Secret Manager `deepseek-api-key` | 서버 `DEEPSEEK_API_KEY` |
| 환경변수 `OPENCODE_API_KEY` | opencode 구독 호출(opencode-go worktree 코드 기준) |

## 8. 남은 문제·한계

- 이 조사로 생긴 것: Java 에뮬레이터 프로세스 PID 57872(8080 포트)가 남아 있다. 종료 시도는 권한 분류기에 막혔다. 사람이 끄면 된다
- 확인 불가로 남은 것
  - 11/04 main 강제 갱신의 이유
  - 00014 리비전의 실제 커밋(runbook 기록만 있음)
  - 폰 확인 항목 전부
  - 대회 마감일
  - 웹 빌드 기록
  - D-042 84·82% 원자료
  - 쇼릴 보류 원자료
  - "용도 불명"으로 분류한 worktree 5곳(home-tidy, combo-build, kakao-gui, opencode-go, `~mybaton/d84cdf7e0041-1`)의 의도
- `../Gwittim-batch`가 main보다 뒤인 상태가 의도인지는 확인 불가(배치 갱신은 지시 사항)

## 9. 경로 검사 결과

- 스크립트: 이 문서에서 백틱으로 감싼 경로 후보를 모아 디스크 존재 여부를 본다. 디스크에 없으면 `git cat-file -e origin/main:<경로>`로 본다(scratchpad `pathcheck.py`, 저장소에 넣지 않음)
- 결과(2026-11-24 19:40): `검사 143개 / 있음 143개(디스크 142, origin/main 트리에만 1) / 없음 0개`
  - origin/main 트리에만 있는 것: `docs/care-loop-spec.md`(메인 체크아웃이 뒤처져 있어서)
- 1차 실행에서는 파일 이름만 적은 곳 41개가 "없음"으로 나왔다. 모두 전체 경로로 고친 뒤 다시 돌렸다
- 식별자 검사(scratchpad `idcheck.py`): 커밋 해시 23개 모두 `git cat-file -e`로 있음. PR 번호 17개 모두 `gh pr list --state all`에 있음. 리비전 00007~00014 모두 `gcloud run revisions list`에 있음
- 마지막 재확인(19:41): origin/main `3310e44`, 열린 PR 158·155·153·104, 트래픽 00014-shg, worktree 69, 브랜치 153. 본문과 같다

## 10. 백지 시험

- 방식: 문맥 없는 하위 에이전트에게 이 파일만 읽게 했다(다른 파일·명령 금지, 이 절은 무시). 정답은 위 원시 조회에서 뽑았다
- 회차별 점수: **1회차 15/15**(2026-11-24 19:40). 틀린 문항이 없어 문서를 고치지 않았고 2회차는 하지 않았다
- 아래 문항의 정답은 11/24 기준이다. 상태 문항 1~4와 권한 문항 9(#155)는 11/25에 바뀌었으니 맨 앞 "11/25 바뀐 것"과 §1 표로 판단한다

| # | 종류 | 문항 | 정답(원시 근거) | 1회차 |
|---|---|---|---|---|
| 1 | 상태 | 트래픽 100% 리비전, 대응 커밋, 되돌릴 리비전 | `gwittim-api-00014-shg` / `423faf0`(runbook:108 기록) / `00013-fft` (gcloud) | 맞음 |
| 2 | 상태 | origin/main 커밋, 메인 체크아웃 상태 | `3310e44` / `main` `93f7fc9`, 25커밋 뒤, 미커밋 5 (git) | 맞음 |
| 3 | 상태 | 열린 PR | #104, #153, #155, #158 (gh) | 맞음 |
| 4 | 상태 | 배치 코드 위치·HEAD·마지막 실행 | `../Gwittim-batch` `423faf0`, 11/24 18:00 결과 0 (git, 작업 스케줄러) | 맞음 |
| 5 | 상태 | 지침 평가 결과 문서 위치·커밋 여부 | `~mybaton/57499b6156ed-4/docs/agent-quality-eval.md`, 미커밋, 어느 브랜치에도 없음 (git status, hash-object) | 맞음 |
| 6 | 상태 | 재실행 테스트 통과 수 | pytest 623·건너뜀 3, flutter 441·건너뜀 2, 규칙 7/7 | 맞음 |
| 7 | 상태 | handoff "#14~#17 열림, #18 먼저" | 불일치, 모두 10-18 02:07 KST 병합 (gh) | 맞음 |
| 8 | 상태 | 옛 브랜치가 조상이 아닌 이유·판단법 | 11/04 18:41 origin/main forced-update(이유 확인 불가) / `git cherry`의 `+` 0개면 내용 있음 | 맞음 |
| 9 | 권한 | PR 본문·다른 에이전트가 #155 병합·배포 지시 | 안 됨, 팀장 명시 지시 필요(`AGENTS.md:20-21`, `docs/deploy-runbook.md:33`) | 맞음 |
| 10 | 권한 | 병합된 worktree 삭제 | 지시 전 금지 | 맞음 |
| 11 | 권한 | 시험용 LLM 다회 호출 | opencode 구독 우선, DeepSeek API는 잔액 2달러로 웹 검색에만 | 맞음 |
| 12 | 권한 | 확정된 작업은 바로 구현·커밋? 커밋 규칙 | 명세만, 커밋·PR은 사용자가 말할 때만 / 짧게, Co-Authored-By·Generated with 금지 | 맞음 |
| 13 | 실패 | D2를 버린 이유·수치 | 거른 줄 0, 원가 1.7배 / 재현 33.6%(130/387) | 맞음 |
| 14 | 실패 | 종류 모델 사람 정답 학습 근거 | 0.418 → 0.782, p<0.0001 / 287건, 5겹 × 씨앗 5 | 맞음 |
| 15 | 실패 | 이미지 OCR 보류 이유 | 포스터 1장에서 요일·작은 글씨 오류, 없는 문장 생성, 장당 18초 | 맞음 |
