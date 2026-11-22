# 2단계 잣대 작업 명세

- 작성일: 2026-11-13
- 상태: **제안 (팀장 승인 전, 미구현)**
- 근거: [stage2-prep-spec.md](stage2-prep-spec.md) §1·§2.1·§4
- 범위: 범위 결정(준비 명세 §6) 없이 시작할 수 있는 작업만 담는다. 폰 알림 수신, Dart 이식, 교외 공고 에이전트는 이 명세에 없다.
- 작업 뒤 검토는 §6 목록으로 한다.

## 1. 공통 규칙

- 원문·라벨·정답표는 저장소에 넣지 않는다. 놓는 곳은 `localModel/kakaoTalk_data/`(git 제외)와 `data/local/`(git 제외)뿐이다.
- 저장소에 넣는 것은 스크립트, 합성 문장 골든, 테스트, 문서다.
- 새 라이브러리 없음. 통계는 표준 라이브러리로 계산한다. Keras가 필요한 스크립트만 `localModel/.venv`를 쓴다.
- 기존 `review_set.csv`, `labels_gemma.jsonl`, `backend/classifier/models/*.bin`은 고치지 않는다.
- 모델·문턱·`MODEL_VERSION`·SPEC·계약·앱 코드는 바꾸지 않는다.
- 작업 하나에 PR 하나. `main`에 직접 푸시하지 않는다.

## 2. 작업

순서: W1 → W2 → (사람 라벨) → W3. W4·W5는 W1 뒤 아무 때나.

### W1. 통계 함수와 현재 수치 재현 스크립트

**새 파일**

- `tools/evalstats.py` — 순수 함수, 표준 라이브러리만
  - `wilson(k, n)` → 95% 구간
  - `mcnemar_exact(b, c)` → 양측 정확 p
  - `bootstrap_ci(ids, fn, seed=0, rounds=5000)` → 2.5%·97.5% 분위
  - `cohen_kappa(a, b)` → 두 라벨 목록의 κ
  - `paired_sample_size(psi, delta)` → 양측 5%, 검정력 80%
- `tools/eval_kakao_classifier.py` — 읽기 전용. 인자 `--data-dir`(기본 `localModel/kakaoTalk_data/processed`)
  - 채점 대상은 `train_keras.load_test_answers`와 같은 규칙으로 고른다(정답 칸이 찬 행 중 `notices.jsonl`에 있는 것).
  - 자체 모델 예측은 `backend/classifier`의 표준 라이브러리 추론으로 낸다.
  - 출력: 종류 정확도와 Wilson 구간, 방법 쌍별 McNemar, 관심사 F1(배운 꼬리표 / 코드 전체)과 부트스트랩 구간, 캐스케이드 F1과 Gemma 호출률(시험 세트 / 전체), 시험 세트의 '판단 갈림' 비율과 전체 비율.
  - `--json` 을 주면 같은 값을 JSON 한 덩어리로 낸다.
- `backend/classifier/tests/test_evalstats.py` — 합성 값으로 함수 검사

**기대 값** (2026-11-10 측정. 스크립트가 지금 자료로 이 값을 내야 한다)

| 항목 | 값 |
|---|---|
| 채점 대상 | 47 |
| 종류 정확도 규칙 / Gemma / 자체 | 19 / 28 / 30 |
| Wilson 구간(자체) | 0.495 ~ 0.760 |
| McNemar 자체 vs Gemma | 5 대 3, p 0.727 |
| McNemar 자체 vs 규칙 | 17 대 6, p 0.035 |
| 관심사 F1 배운 3개: 규칙 / Gemma / 자체 | 0.667 / 0.750 / 0.774 |
| 관심사 F1 코드 전체: 캐스케이드 | 0.679 |
| Gemma 호출 | 시험 12/47, 전체 61/287 |
| 판단 갈림 | 시험 25/47, 전체 67/287 |

**단위 테스트에 넣을 값**

- `wilson(30, 47)` ≈ (0.495, 0.760), `wilson(0, 10)`의 아래 끝 0
- `mcnemar_exact(5, 3)` ≈ 0.727, `mcnemar_exact(17, 6)` ≈ 0.035, `mcnemar_exact(0, 0)` = 1
- `cohen_kappa`: 완전 일치 1, 한쪽이 한 값만 낸 경우 0, 손계산한 2×2 예 하나
- `paired_sample_size(0.17, 0.10)` = 132

### W2. 가림 라벨 표와 일치도

**새 파일**

- `localModel/make_label_sheet.py`
  - 입력: `notices.jsonl` 287건
  - 출력: `processed/label_sheet_A.csv`, `label_sheet_B.csv`
  - 열: `id`, `방`, `제목`, `본문`(전체), `정답_관심사`, `정답_카테고리`, `정답_전체대상`, `메모`
  - **규칙·Gemma의 답과 근거 열을 넣지 않는다.**
  - 행 순서는 작업자마다 다른 씨앗으로 섞는다(A는 1, B는 2). 방 순서로 두지 않는다.
  - 이미 채운 표가 있으면 덮어쓰지 않고 멈춘다(`--force` 없음).
  - 표 맨 위가 아니라 별도 파일 `processed/label_guide.txt`로 허용 코드 목록을 낸다: 관심사는 `contracts/dictionaries/interests.json`의 id와 `없음`, 종류는 카테고리 사전의 id.
- `localModel/label_agreement.py`
  - 입력: 채운 A·B 표
  - 검사: 사전에 없는 코드, 빈 칸 → 행 번호와 함께 오류로 내고 멈춘다.
  - 출력: 종류 κ, 관심사 꼬리표별 κ(양쪽 합쳐 5건 미만인 꼬리표는 건수만), 전체 대상 κ, 갈린 행 목록 `processed/label_disagreements.csv`(A 답, B 답, 빈 `합의` 칸).
  - `--merge`: 갈린 행의 `합의` 칸이 모두 찼을 때만 `processed/labels_human.jsonl`을 쓴다. 한 줄에 `id`, `interest_ids`, `category`, `for_all_students`, `a`, `b`(합의 전 답).
  - 끝에 `labels_human.jsonl`의 SHA-256을 출력한다.

**사람이 할 일** (스크립트 밖)

- 두 작업자가 서로의 표와 `labels_gemma.jsonl`·`review_set.csv`를 보지 않고 채운다.
- κ가 0.6에 못 미치는 항목은 꼬리표 정의를 `label_guide.txt`에 보충하고 그 항목만 다시 매긴다.
- 합의 뒤 SHA-256과 날짜를 `docs/decisions.md` 새 항목에 적는다. 그 전에는 W3의 학습을 돌리지 않는다.

### W3. 교차 검증 모드

**고칠 파일**: `localModel/train_keras.py`

- 새 옵션 `--cv`: `labels_human.jsonl`이 있어야 돈다. 없으면 안내하고 멈춘다.
- 겹: 5겹, 방과 사람 정답 종류로 층화. 씨앗 0~4로 5번 반복.
- 학습 정답은 지금처럼 Gemma 라벨, 채점 정답은 사람 라벨. 문턱은 각 겹의 학습 쪽에서 떼어 낸 검증 세트로만 정한다. 채점 겹은 문턱·단어장·조기 종료 어디에도 쓰지 않는다.
- 비교 방법: 규칙, Gemma, 자체 모델, 캐스케이드(±0.05). 종류와 관심사 모두.
- 출력: `models/cv_<target>_<unit>_<arch>.json`
  - 접힌 예측 전체(공지 id, 씨앗, 방법별 예측과 확률)
  - 씨앗별 지표와 평균, `tools/evalstats`로 낸 Wilson·McNemar·부트스트랩 구간
  - 겹마다 배운 꼬리표 목록(학습 예시 5건 이상)
  - 사용한 `labels_human.jsonl`의 SHA-256
- 기존 옵션과 `run()`의 동작·출력 파일은 그대로 둔다. `--cv`는 `.keras`·`_vocab.json`을 쓰지 않는다.
- 이 작업은 **기준선 측정**까지다. 오류 사례 재학습과 문턱 재조정은 하지 않는다.

### W4. 합성 문장 골든 확대와 287건 비교 스크립트

**고칠 파일**: `localModel/export_weights.py`

- `CHECK_TEXTS`를 3개에서 50개 안팎으로 늘린다. 모두 직접 쓴 합성 문장이고 실제 공지 문장을 옮기지 않는다.
- 꼭 넣을 경우: 이모지(📢 같은 두 단위 글자), 전각 영문·숫자, 로마 숫자(Ⅱ), 600자 초과, 빈 글, 공백만, 링크만, 문장부호만, 단어장에 없는 글자만, 영문 대소문자 혼합, 줄바꿈·탭.
- 내보내기를 다시 돌려 `backend/classifier/models/*.json`의 `check`만 늘어나야 한다. `.bin`은 SHA-256이 그대로여야 하고, `.json`의 `check` 밖 값도 그대로여야 한다.

**새 파일**: `localModel/check_parity.py`

- Keras 원본과 표준 라이브러리 추론을 287건으로 비교해 판정 일치 수와 최대 확률 차를 출력한다. **파일을 쓰지 않는다.**
- 기대 값: 관심사 287/287(최대 차 1e-6 미만), 종류 287/287.

기존 `test_matches_keras_on_check_texts`는 고치지 않아도 늘어난 `check`를 모두 검사한다.

### W5. 게시판 정답표 표본과 채점

**새 파일**

- `tools/make_board_gold_sheet.py`
  - 입력: `data/local/notices.json`에서 게시판 4개(`mjc_www_*`) 공고
  - 게시판별 비례로 100건(공지 34, 채용 34, 장학 20, 근로 12), 씨앗 0. 건수가 모자라면 있는 만큼 뽑고 알린다.
  - 출력: `data/local/gold/board_sheet_A.csv`, `_B.csv`. 열: `notice_id`, `게시판`, `제목`, `source_url`, 그리고 빈 정답 칸
    - `마감일`(YYYY-MM-DD 또는 `없음` 또는 `판단불가`)
    - `학교`, `학과`, `학년`, `재학상태`(사전 코드, 여러 개는 공백 구분, 조건 없으면 `없음`)
    - `자유조건`(한 줄에 하나, 원문 문구 그대로)
    - `누구나`(Y/N)
    - `메모`
  - **분석 결과(요약·조건·마감일)를 열에 넣지 않는다.** 정답은 `source_url`의 원문과 포스터를 보고 적는다.
- `tools/eval_board_extraction.py`
  - 입력: 합의된 정답표 `data/local/gold/board_gold.csv`, `data/local/notices.json`
  - 지표
    - 마감일: 정밀도·재현율(날짜 완전 일치), 틀린 날짜 건수와 목록
    - 구조 조건: 조건 단위 정밀도·재현율(학과·학년·재학 따로)
    - 자유 조건: 정답 문구가 `conditions`의 근거 또는 `unresolved_conditions`에 든 비율. 비교는 공백·문장부호를 뗀 뒤 포함 관계로 한다. 놓친 문구 목록.
    - 판정: 고정 프로필 4개로 `backend.recommendation.eligibility.evaluate`를 돌려 정답 판정과의 3×3 혼동표
  - 정답 판정은 정답표에서 기계적으로 만든다: `누구나` Y이고 자유조건 없음 → `met`, 구조 조건이 프로필과 어긋남 → `not_met`, 자유조건이 하나라도 있음 → `needs_check`, 그 밖에 구조 조건이 모두 맞음 → `met`.
  - **맨 위에 '틀린 지원 가능' 건수와 목록**을 낸다(정답이 `met`이 아닌데 `met`).
  - 프로필 4개는 `fixtures/`의 합성 프로필을 쓰거나 스크립트 안에 고정한다: 경영학과 2학년 휴학, 컴퓨터공학과 2학년 재학, 졸업, 1학년 재학.
- 두 표의 일치·합의는 W2와 같은 방식. `label_agreement.py`를 그대로 쓸 수 없으면 `마감일`·`누구나`만 일치율을 내고 갈린 행 목록을 만든다.

## 3. 하지 않는 것

- 모델 재학습·교체, 문턱 변경, 종류 모델에 `other` 추가
- 수정 명세([eligibility-ranking-fix-spec.md](eligibility-ranking-fix-spec.md)) W1·W2 구현
- 앱 코드, Dart 추론, 알림 접근 권한
- 교외 출처 조사·수집, 검색 수단 연결
- 사람이 매겨야 할 정답을 스크립트나 모델로 채우기
- Firestore 쓰기, 배포, 배치 설정 변경

## 4. 폰 알림 확인 절차 (팀장 직접, 코드 없음)

1. S25 Ultra를 USB 디버깅으로 연결하고 `adb devices`에 보이는지 확인.
2. 학교 채널 알림톡이 온 직후, 알림을 지우기 전에 실행:

   ```bash
   adb shell dumpsys notification --noredact > notif_dump.txt
   ```

3. `notif_dump.txt`에서 카카오톡(`com.kakao.talk`) 학교 채널 알림만 남기고 나머지는 지운다. 파일은 `data/local/`에 둔다.
4. 알림마다 적을 것: 방 이름이 든 칸, 본문 칸과 확장 본문 칸의 글자 수, 같은 공지의 내보내기 본문 글자 수, 이미지·버튼이 어떻게 보이는지.
5. 6개 방에서 각 1건 이상 모이면 표로 정리해 준비 명세 §2.1 전제 A에 결과를 적는다.

## 5. 완료 기준

- `uv run pytest` 전체 통과(새 테스트 포함), `uv run python tools/validate_contracts.py` 통과
- W1: `uv run python tools/eval_kakao_classifier.py`가 §2 W1의 기대 값을 낸다.
- W2: 합성 공지 5건으로 표 만들기 → 채우기 → 일치도 → 합치기가 끝까지 돈다. 표에 규칙·Gemma 열이 없다.
- W3: `--cv` 출력의 채점 건수가 사람 정답이 있는 공지 수 × 5(씨앗)다. 기존 명령 `train_keras.py --unit char --arch avg`의 지표가 작업 전과 같다.
- W4: `.bin` SHA-256 작업 전후 같음, `check` 50개 안팎, `check_parity.py`가 287/287.
- W5: 합성 정답표로 채점 스크립트가 돌고, 틀린 '지원 가능'을 일부러 넣은 합성 사례를 잡아낸다.
- `git status`에 원문·라벨·정답표 파일이 없다.
- PR 본문에 실행한 명령과 실제 출력을 적는다. 못 돌린 것은 '미실행'과 사유.

## 6. 검토 때 볼 것

- **가림**: 라벨 표와 정답표에 모델·규칙·분석 결과가 한 글자도 안 들어갔는가. 행 순서가 섞였는가.
- **새는 곳**: 교차 검증에서 채점 겹이 단어장·문턱·조기 종료에 쓰이지 않는가. 같은 공지가 학습과 채점에 함께 들어가지 않는가(`send_count`가 2 이상인 묶인 공지 포함).
- **채점 규칙 일치**: 새 스크립트의 F1·정확도 정의가 `train_keras.tag_scores`와 같은가. 기대 값 표와 숫자가 맞는가.
- **통계 함수**: 경계값(0건, 전부 맞음, 불일치 0쌍)에서 오류가 나지 않는가.
- **골든**: `.bin`이 정말 그대로인가. 합성 문장에 실제 공지 문구나 이름이 없는가.
- **게시판 채점**: 자유 조건 비교가 너무 느슨해서 놓친 조건을 잡은 것으로 세지 않는가. 틀린 '지원 가능' 정의가 준비 명세 §1.5와 같은가.
- **저장소 오염**: 원문·개인정보·`.keras`·덤프 파일이 커밋되지 않았는가. 기존 파일(`review_set.csv`, 모델 가중치)이 바뀌지 않았는가.
- **범위**: §3의 항목을 건드리지 않았는가.

## 7. 열린 사항

- 카테고리 사전에 `other`가 코드로 있는지 확인하지 않았다. 없으면 `label_guide.txt`의 종류 목록에 `other`를 넣을지 팀장에게 묻는다(기존 정답 47건 중 7건이 `other`).
- `notices.jsonl`의 묶인 공지(`send_count`)가 몇 건인지 세지 않았다.
- W3의 실행 시간(학습 25회)은 재 보지 않았다.
