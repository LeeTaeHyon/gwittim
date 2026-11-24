# 공고 분석 자체 모델 반영 명세 (PR #104 → main)

- 작성: 2026-11-25
- 대상: 구현을 맡는 에이전트. 이 문서만 읽고 시작할 수 있게 적음
- 근거: D-042(PR #104 안에 있음, main에는 아직 없음), `docs/extract-model.md`(같은 PR), `docs/stage2-results.md` §4
- 산출물 하나: **PR #104를 지금 main 위에서 병합 가능한 상태로 만들고, 점수가 그대로인지 다시 잰 결과를 PR에 적는다**
- 하지 않는 것: main 병합, 배치 폴더 갱신, 실제 배치 실행, 재학습. 이 셋은 팀장이 따로 지시(§7)

## 1. 지금 상태 (2026-11-25 확인)

- PR #104 `feat/extract-model`: 커밋 1개(`e4de4de`, 11/18). main보다 184커밋 뒤
- main·정기 배치는 공고 마감·조건을 **규칙 + Gemma**로 뽑음. 11/24 18:00 배치 기록에 `gemma4:12b`
- 가중치는 이미 있음: `C:\Users\dlxog\Desktop\all\Code_Project\Gwittim\data\local\models\extract-v1\` (5개 파일, git 제외). 정기 배치의 `-DataDir`가 이 `data\local`이라 옮길 필요 없음
- 작업 폴더: `.claude/worktrees/extract-model`(브랜치 `feat/extract-model`). 있으면 그대로 쓰고, 없으면 worktree를 새로 만듦. 메인 체크아웃에서 브랜치를 바꾸지 않음
- 실험 자료: `data/local/extract_distill/`(git 제외). 비교 `compare.py`, 결과 `compare_out/`, torch가 있는 파이썬은 `smoke/.venv`

## 2. main과 맞추기

- `origin/main`을 `feat/extract-model`에 **병합**(이 저장소 방식. rebase·강제 푸시 안 함)
- 충돌 파일 5개와 푸는 기준

| 파일 | 기준 |
|---|---|
| `backend/analysis/rules.py` | main 것을 살리고 `ANALYSIS_VERSION`만 `rule-0.11`로. 주석 맨 앞에 `0.11: 날짜 범위 끝 형식 보강(D-042)` 추가. PR의 `rule-0.9`는 main의 `rule-0.9`(공통 규칙 개선)와 번호만 같고 내용이 다름 |
| `backend/analysis/dates.py` | main의 rule-0.9(기간형 신청 끝날짜 등) 변경과 PR의 범위 끝 형식 보강(`'25.`, `~ 20.(금)`, `\~`, `…부터 …까지`, 빈 요일 괄호)을 **둘 다** 살림. 한쪽을 통째로 고르지 않음 |
| `backend/analysis/llm.py` | main 것 위에 PR의 `extract` 인자(요약만 쓰기), `-summary` 버전 꼬리, 실패 시 `_analysis_version` 넘기기를 다시 얹음. 요약만 쓰는 조건은 **둘 중 하나라도**: `fields["category"] == "admin_notice" or not self.extract`. 한쪽만 남기지 않음 |
| `backend/analysis/tests/test_llm.py` | 버전 문자열은 `rule-0.11` 기준으로. main 쪽 새 시험은 모두 남김 |
| `docs/decisions.md` | D-042를 번호 순서(D-041 뒤, D-043 앞)에 둠. main의 D-043 이후는 그대로 |

- 자동 병합되는 `scripts/run_batch.ps1`, `tests/test_dates.py`도 결과를 눈으로 확인. `run_batch.ps1`은 §3 범위와 맞아야 함
- `uv.lock`은 병합 뒤 `uv lock`으로 다시 만들고, `extract` 그룹 밖 패키지 버전이 main과 달라지지 않았는지 diff로 확인

## 3. 적용 범위

- 자체 모델을 쓰는 곳: **명지 게시판(`mjc_www`)과 알림톡(`mjc_kakao`)만**. 학습·시험 자료가 명지 공고뿐이라서
- 그대로 두는 곳: 숭의(`sewu_www`), 교외(`wevity`·`contestkorea`, `common/external_cli.py`). 코드·실행 명령 모두 손대지 않음
- `scripts/run_batch.ps1`: `--group extract`는 `mjc_www`·`mjc_kakao` 두 줄에만 붙음. 숭의·교외 줄은 main 그대로
- 가중치가 없거나 torch가 없으면 예전 방식(규칙 + Gemma)으로 동작하는 것은 PR대로 유지

## 4. main의 새 규칙과 부딪히는 곳 (꼭 고칠 것)

### 4.1 졸업 예정자 (D-046, rule-0.10)

- main: '졸업 예정'이 있는 줄은 재학 상태 조건으로 만들지 않고 직접 확인 조건으로 보냄
- 문제: `ExtractModelAnalyzer._conditions`는 규칙이 `enrollment_status`를 안 냈으면 모델 꼬리표(`enr_graduated` 등)로 조건을 채움 → 그 줄이 다시 '졸업생' 조건이 될 수 있음
- 고칠 방향: 규칙이 D-046으로 직접 확인에 보낸 줄(같은 판별 함수·정규식을 재사용)은 모델이 재학 상태 조건으로 만들지 않음. 새 정규식을 따로 쓰지 않음
- 시험: '졸업 예정자' 줄에 모델이 `enr_graduated`를 붙인 가짜 예측기로, 재학 상태 조건이 생기지 않고 직접 확인 조건이 남는지

### 4.2 rule-0.9의 조건 규칙 (꼭 고칠 것)

- main의 rule-0.9: 재학 상태 여러 값, 신청자 조건 줄, 행정 공지 조건 제외, 학년 전체 나열 무시
- 문제: `ExtractModelAnalyzer.analyze`는 분류와 상관없이 `_deadline`·`_conditions`·`_others`를 돌림. 규칙이 **일부러 비운** 필드가 되살아나는 구조(11/24 코드 검토로 확인)
- 고칠 것 두 가지. 둘 다 시험을 더함
  1. 행정 공지: 규칙 결과의 `category`가 `admin_notice`면 모델을 돌리지 않고 규칙 결과를 그대로 돌려줌(모델 집계 `model_analyzed`에도 넣지 않음). 시험: 업체 계약 공고 제목 + 모델이 마감·조건 꼬리표를 붙인 가짜 예측기 → 마감·조건이 비어 있음
  2. 학년 전체: 모델이 모은 학년 값이 1~4 전부면 학년 조건을 만들지 않음(규칙의 '학년 전체 나열 무시'와 같은 뜻). 시험: '1~4학년 누구나' 줄에 `grade_1`~`grade_4` → 학년 조건 없음
- 그 밖에 규칙이 비운 필드를 모델이 되살리는 사례가 시험 94건·평가셋에서 나오면 같은 방식(규칙의 판별을 재사용)으로 막음. 없으면 "확인함, 사례 없음"으로 PR에 적음

### 4.3 학교 코드

- `uni_mjc` 꼬리표는 출처의 학교가 명지일 때만 조건이 됨(PR 코드 그대로). §3에서 숭의는 모델을 안 쓰므로 영향 없음. 이 동작을 지키는 시험이 없으면 하나 더함(출처 학교가 다르면 학교 조건 안 생김)

### 4.4 그 밖에 확인만

- `unresolved_conditions[].note`의 `"모델 추출"` 값이 계약(`contracts/`)과 앱 표시에서 문제없는지: `uv run python tools/validate_contracts.py`, 앱에서 `note`를 화면에 그대로 쓰는 곳이 있는지 검색. 화면에 그대로 나오면 멈추고 보고
- `Dockerfile`(Cloud Run 서버)이 `extract` 그룹을 설치하지 않는지. 서버 이미지에 torch가 들어가면 안 됨
- 알림톡 미리보기 공고(D-040, 200자)와 본문 저장(`notice_bodies`, PR #155는 아직 미병합)은 이번 범위 밖. 건드리지 않음

## 5. 다시 재기

병합으로 날짜 파서와 규칙이 바뀌었으므로 PR의 숫자를 그대로 믿지 않음.

1. 시험 94건: `data/local/extract_distill/compare.py`를 병합된 코드로 다시 돌림(`smoke/.venv` 파이썬, 저장소 코드를 경로로 가리킴)
   - 기준(11/18): 마감 맞음 84, 틀린 마감 + 없는데 만든 마감 1, 기타 조건 찾은 비율 82%
   - 같은 표에 규칙만 / 규칙 + Gemma(저장된 `compare_out/gemma` 결과 재사용, Gemma를 다시 부르지 않음) / 자체 모델
2. 공통 평가셋 35건(`data/local/eval_common/`, 명지 사람 정답 20 + 숭의 15): `tools/eval_board_extraction.py`
   - 명지 20건: main(규칙) 대비 자체 모델. 사람 정답으로 잰 숫자는 이것뿐이라 꼭 적음
   - 숭의 15건: 참고로만 한 번 잼(적용은 안 함). 숫자만 PR에 적음
3. 문턱(`meta.json`)은 바꾸지 않음. 시험 세트를 보고 값을 고르지 않음

### 합격 기준

- 시험 94건: 틀린 마감 + 만든 마감 ≤ 2, 마감 맞음 ≥ 82, 기타 조건 ≥ 80%
- 명지 사람 정답 20건: 마감 정밀도와 구조 조건 정밀도가 main(규칙)보다 낮지 않음
- 못 넘기면 원인을 사례로 적고 **멈춤**(문턱·규칙을 더 고쳐 맞추지 않음). 팀장이 정함

## 6. 검증과 PR

- `uv run --group extract pytest backend` 전체 통과(건수 적기). `uv run pytest backend`(torch 없이)도 통과해야 함: torch가 없으면 관련 시험은 건너뜀
- `uv run python tools/validate_contracts.py` 통과
- 로컬 건조 실행 1회: 메인 `data/local`을 **복사한 임시 폴더**를 `--data-dir`로, `GWITTIM_FIREBASE_PROJECT_ID` 없이
  - `uv run --group extract python -m backend.collectors.mjc_www --data-dir <복사본> --no-llm`
  - 요약 JSON의 `extract_model.analyzed`가 0보다 크고 `fallback_rule_only`가 0인지, 걸린 시간
  - 원본 `data/local`과 Firestore에는 쓰지 않음
- 숭의·교외 전후 비교 1회: 자체 모델은 안 쓰지만 `rule-0.11`과 `dates.py` 변경 때문에 병합 뒤 첫 배치에서 숭의·교외 공고도 다시 분석됨. 결과가 얼마나 바뀌는지 미리 셈
  - 메인 `data/local`을 **새로 복사한 임시 폴더**를 씀(위 명지 건조 실행 폴더와 따로). `GWITTIM_FIREBASE_PROJECT_ID` 없이
  - 전: 복사본의 `notices.json` 그대로(지금 main 코드로 분석된 결과)
  - 후: 병합된 코드로 복사본에 수집기를 실행. Gemma를 켬(요약 비교가 목적이라 `--no-llm` 안 씀)
    - `uv run python -m backend.collectors.sewu_www --data-dir <복사본>`
    - `uv run python -m backend.collectors.wevity --data-dir <복사본>`, `uv run python -m backend.collectors.contestkorea --data-dir <복사본>`(`run_batch.ps1`의 교외 줄과 같은 모듈)
  - 비교 대상: `source_id`가 `sewu_www_*`·`wevity_*`·`contestkorea_*`이고 전후 둘 다 있는 `notice_id`만. 그 사이 새로 생기거나 사라진 공고는 건수만 따로 적음
  - 후 결과의 `analysis_version`이 `rule-0.11`로 시작하는지 확인. 다시 분석되지 않은 공고가 있으면 건수와 이유를 적음
  - 출처별로 셀 것
    - 마감: `application_deadline`의 날짜·시각(근거 문구 제외)이 달라진 건수. 새로 생김, 사라짐, 바뀜으로 나눔
    - 조건: `eligibility.conditions`의 (field, operator, value) 묶음이 달라진 건수, `unresolved_conditions` 개수가 달라진 건수
    - 요약: `summary` 문자열이 달라진 건수, 전에는 있었는데 후에 `null`이 된 건수(Gemma 실패)
  - 마감·조건이 달라진 공고는 **모두** 사례로 적음: 공고 ID, 전 값, 후 값, 근거 줄. 요약은 바뀐 예 3건만
  - 비교 스크립트는 `data/local/extract_distill/compare_sources.py`(git 제외)에 둠. 저장소에 새 도구를 추가하지 않음
  - 합격 문턱은 없음. 다만 마감이 사라졌거나, 근거 줄과 맞지 않게 바뀐 사례가 1건이라도 나오면 **멈추고 보고**(규칙을 더 고치지 않음)
  - 원본 `data/local`과 Firestore에는 쓰지 않음. 교외 수집은 실제 사이트에 요청하므로 D-038 상한(기본값)을 그대로 둠
- 되돌리기 리허설 1회(병합 전): §7-6 순서로 되돌렸을 때 결과가 반영 전과 같은지 복사본에서 확인
  - 메인 `data/local`을 **새로 복사한 임시 폴더**(위 두 건조 실행 폴더와 따로). `GWITTIM_FIREBASE_PROJECT_ID` 없이
  - main 코드 실행용으로 `origin/main` 위에 분리된(detached) worktree를 새로 만듦. 배치 폴더 `Gwittim-batch`는 쓰지 않고 건드리지 않음
  - 실행 단계: `run_batch.ps1`과 같은 순서로 `mjc_www` → `sewu_www` → `wevity` → `contestkorea` → `mjc_kakao`(`--export-dir`는 배치와 같은 폴더, Firestore가 없으므로 받은편지함은 안 읽음). Gemma 켬. 병합 코드는 `uv run --group extract`, main 코드는 `uv run`
  1. 백업: 복사본의 `notices.json`을 같은 복사본 안의 `notices.backup.json`으로 복사
  2. 병합 코드 실행: 병합된 브랜치 worktree에서 위 단계를 복사본으로 돌림. 분석 버전이 `rule-0.11`로 바뀌었는지 확인
  3. 백업 복원: `notices.backup.json`을 복사본의 `notices.json`에 덮어씀. `pipeline/`은 그대로 둠
  4. main 코드 재실행: main worktree에서 위 단계를 같은 복사본으로 다시 돌림
  5. 공고별 비교: 4의 `notices.json`과 1의 백업을 `notice_id`로 맞춰 비교. 백업에 있던 공고만 대상(그 사이 새로 생긴 공고는 건수만)
     - 같아야 하는 것: `analysis_version`, `summary`, `category`, `interest_tags`, `related_majors`, `related_roles`, `application_start`, `application_deadline`, `deadline_note`, `activity_period`, `eligibility`, `publication_status`
     - 비교에서 빼는 것(원래 매 배치 바뀜): `last_collected_at`, `last_verified_at`, `lifecycle_status`, `changed_fields`
     - 원문이 그 사이 바뀐 공고(`notice_version`이 백업과 다름)는 다시 분석되는 게 정상이므로 따로 건수만 적음
  - 합격: 위 필드가 다른 공고 0건. 1건이라도 다르면 공고 ID와 다른 필드를 적고 **멈추고 보고**(§7-6 순서를 고치지 않음)
  - 비교 스크립트는 `data/local/extract_distill/compare_rollback.py`(git 제외). 원본 `data/local`과 Firestore에는 쓰지 않음
- PR #104 본문을 고침(짧게, 변경점만): 버전 `rule-0.11`, 적용 범위(명지 게시판·알림톡), D-046 보호, 다시 잰 표
- 문서: `docs/extract-model.md`의 버전·범위 문장, `docs/decisions.md` D-042에 "2026-11-25 보완"(버전 0.11, 숭의·교외 제외, 졸업 예정 줄 보호)
- `docs/stage2-results.md`, `docs/handoff.md`는 **고치지 않음**(실제 배치에 반영된 뒤 팀장 지시로)
- 커밋 메시지는 짧고 담백하게. `Co-Authored-By`·`Generated with` 꼬리말 금지

## 7. 병합 뒤 할 일 (이 명세 범위 밖, 팀장 지시로)

1. PR #104 병합. 그 전에 포스터 반영(#161) 정기 배치가 한 번 이상 정상으로 돌아 `data\local\notices.json`의 명지 공고에 `poster_url`이 들어갔는지 확인. 안 들어간 상태로 반영하면 첫 실행에서 포스터만 붙고 재분석은 다음 배치로 밀림(11/24 건조 실행에서 66건)
2. **백업(안전장치)**: 배치 폴더를 바꾸기 전에
   - 배치 폴더의 지금 커밋을 적어 둠: `git -C Code_Project\Gwittim-batch rev-parse HEAD` (11/24 기준 `cf77439`)
   - 메인 `data\local`의 `notices.json`, `pipeline\` 폴더, `external_excluded.json`을 `data\local\backup_extract_<날짜>\`로 복사
   - 앱에 보이는 공고 수를 출처별로 적어 둠(`notices.json`에서 `publication_status == "published"`이고 마감 전인 것)
3. 배치 폴더 `Code_Project\Gwittim-batch`를 새 main으로: `git fetch origin` → `git checkout --detach origin/main` → `uv sync --group extract`
4. 정기 배치(09:00·18:00)와 겹치지 않는 시간에 손으로 한 번 실행. 분석 버전이 바뀌어 배치가 다루는 공고를 다시 분석함
   - 명지 게시판(목록 앞 2쪽, 11/24 기준 49건)·알림톡(내보내기 전부, 약 295건): 자체 모델 + Gemma 요약
   - 숭의·교외(저장된 공고 전부, 약 125건): 자체 모델 없이 규칙 + Gemma. 규칙 결과는 0.10과 같고(저장 원문 123건 비교) 요약만 새로 쓰임
   - 11/24 리허설에서 약 47분(게시판 8분, 숭의 4분, 교외 각 5분, 알림톡 25분). 정기 배치 작업 제한 1시간에 가까우므로 꼭 손으로 먼저 돌림
5. **멈춤 기준(안전장치)**: 다음 중 하나라도 나오면 6의 되돌리기를 함
   - `extract_model.fallback_rule_only`가 0이 아님, 또는 `extract_model.analyzed`가 0
   - 출처별 앱 노출 공고 수가 2의 기록보다 10% 넘게 줄어듦
   - 앱에서 명지 공고 5건·숭의 2건·교외 2건을 열어 봤을 때 마감이 원문과 다르거나, 행정 공지에 조건이 붙었거나, 졸업 예정 줄이 졸업생 조건이 된 사례
6. **되돌리기 (원래 분석 그대로 복원)**: 순서를 지킴
   1. 2에서 백업한 `notices.json`, `pipeline\`, `external_excluded.json`을 메인 `data\local`에 모두 덮어씀. `pipeline\`도 꼭 되돌림: 숭의·교외 수집기는 `pipeline\`에 있는 공고를 건너뛰므로, 반영 중 새로 들어온 공고가 `notices.json`에서 빠진 채 다시 수집되지 않음(11/24 리허설에서 교외 3건). 되돌리면 새 공고로 다시 수집·분석됨
   2. 배치 폴더를 2에서 적은 커밋으로: `git checkout --detach <커밋>` → `uv sync`
   3. 손으로 한 번 실행. 원문·분석 버전이 백업과 같으므로 **다시 분석하지 않고 백업의 분석을 그대로 재사용**(`build_notice`)하고, Firestore 공개본은 분석 버전이 달라 그 내용으로 덮임(`publish`)
   - 결과: 마감·조건·요약이 반영 전과 같음(11/24 복사본 리허설: 기존 공고 633건 차이 0건, 반영 중 새로 생긴 15건 모두 예전 코드로 다시 들어옴). 달라지는 것은 원래도 매 배치 바뀌는 것뿐(확인 시각, 마감 지남 상태, 그 사이 새로 올라온 공고)
   - 1을 건너뛰고 코드만 되돌리면 예전 코드로 **다시 분석**되어 Gemma 요약·보강이 새로 쓰이므로 원래와 똑같다는 보장이 없음. 그래서 1을 먼저 함
   - 가벼운 되돌리기(자체 모델만 끄기): 배치 실행에 `--no-extract-model`을 주거나 가중치 폴더 이름을 바꿈. 이때도 `rule-0.11` 날짜 보강은 남음
7. 문제없으면 배치 기록의 `extract_model.analyzed`·`fallback_rule_only`를 적고, `stage2-results.md` "앱 반영 전" 지우기, `handoff.md`·`deploy-runbook.md` 갱신, 멘토링 페이지 문구 수정. 백업 폴더는 다음 정기 배치 2회가 정상이면 지워도 됨(팀장 판단)

## 8. 끝낼 때 보고

- 바꾼 파일과 요약, 충돌을 어떻게 풀었는지(특히 `dates.py`)
- 실행한 명령과 실제 결과: pytest 건수, 다시 잰 표 2개, 건조 실행 요약, 숭의·교외 전후 비교 표와 마감·조건이 바뀐 사례, 되돌리기 리허설 결과(다른 공고 수, 원문이 바뀐 공고 수)
- 4.2에서 찾은 사례 유무, 4.4 확인 결과
- 합격 기준 통과 여부. 미실행 항목은 "미실행"과 사유
