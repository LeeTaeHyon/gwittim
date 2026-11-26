# 카톡 넘긴 공고 후속 수정 명세 (하위 에이전트용)

- 작성: 2026-11-26 (D-058 실기기 확인 후)
- 기준: `origin/main` 최신. 새 worktree `.claude/worktrees/kakao-share-fix`, 브랜치 `fix/kakao-share-followup`
- 커밋·PR·배포·Firestore 변경 금지. 작업 트리에만 남기고 보고

## 0. 배경 (실기기 확인, 실제 서버 저장본 대조)

- 연합종강총회 공유 글: 계좌번호·예금주 이름이 가려지지 않고 서버에 저장됨(해당 건은 팀장 지시로 삭제함)
- 같은 글 '일시: 12월 14일' → 서버는 `activity_period`로 저장했는데 앱 일정에 안 보임
- "안녕하세요! 전자공학과 학생회입니다." → 지원 조건 `major_id = 전자공학과`로 잘못 읽음
- AI 포럼 글: 같은 글을 두 번 붙여넣어 2건 저장. 일시가 2025년이라 지난 행사인데 화면에서 분명하지 않음
- 릴리스 APK에서 기기 저장값 읽기 실패: `shared_preferences_android` 2.5.1 R8 버그(2.5.2에서 수정)

## 1. 개인정보 가리기 보강 (최우선)

- 대상: 서버 `backend/collectors/mjc_kakao/parser.py`의 `mask`, 기기 `apps/mobile/lib/classifier/kakao_filter.dart`의 `maskPersonal` 둘 다. 두 쪽 결과가 같아야 함(기존 골든 `filter_golden.json` 방식)
- 새로 가릴 것
  - 계좌번호: 은행 이름·'계좌'·'입금' 근처의 10~16자리 숫자(하이픈 포함) → `<계좌>`
  - 예금주: 계좌번호 바로 뒤 괄호 안 이름 `(김태환)`, '예금주: 홍길동' → `<이름>`
- 유의
  - 학교 대표번호·날짜·금액(30,000원)은 가리지 않는다
  - 알림톡 배치 수집에도 같은 함수가 쓰인다. 기존 알림톡 665건 결과가 계좌 줄 말고는 바뀌지 않는지 확인
  - 바꾸면 분류 입력이 달라질 수 있으니 `MODEL_VERSION`은 그대로 두고 영향 건수만 보고
- 테스트: 합성 계좌 문장 골든 추가(실제 계좌번호 금지), 파이썬·Dart 일치

## 2. 앱 일정에 행사일 표시

- 넘긴 공고 결과 화면에서 `activity_period`가 일정에 안 나오는 원인을 찾아 고친다(`SharedNoticeItem` 파싱 또는 `report_screen.dart` 일정 조립)
- 표시
  - 일정: '행사' 또는 '활동 시작/끝' 항목
  - 신청 마감이 없고 행사일만 있으면 요약 칸 '마감'에 "행사일 ○월 ○일" 표시
  - 행사일이 이미 지났으면 '지난 행사' 표시(`lifecycle_status: closed`)
- 공용 공고(학교·교외)의 일정 동작은 바꾸지 않는다. 바꿔야 하면 보고
- 문구는 명사형·합쇼체(해요체 금지)

## 3. 보낸 사람 소개를 조건에서 제외

- 원인: `backend/analysis/rules.py` 학과 조건 정규식이 '학생'으로 '학생회'까지 잡음(795행 근처)
- 수정: '학생회·학회·동아리'처럼 단체 이름이 이어지는 경우, 인사·소개 줄("○○입니다")은 학과 조건에서 뺀다
- `ANALYSIS_VERSION`을 올리고 결정 기록에 남긴다(번호는 decisions.md의 다음 번호)
- 기존 공고 영향: 로컬 notices 사본으로 재분석해 학과 조건이 바뀌는 건수·예시를 보고(Firestore 반영 금지)

## 4. 같은 글 중복 묶기

- 같은 사용자가 가린 본문이 같은 글을 다시 넘기면 새로 저장하지 않고 기존 항목을 돌려준다
- 기준: 공백 정리 후 본문 해시. 하루 상한 계산에도 세지 않는다
- 응답 모양은 그대로(기존 항목). 계약 변경 없음

## 5. 기기 저장값 버그

- `apps/mobile/pubspec.lock`의 `shared_preferences_android`를 2.5.5로(`flutter pub upgrade shared_preferences_android`, `jni` 1.2.1 함께). `pubspec.yaml` 변경 없음
- 릴리스 빌드에서 `flutter clean` 후 확인해야 함(캐시가 남으면 같은 오류가 다시 남)

## 6. 건드리지 않을 것

- 분류 모델 파일·`MODEL_VERSION`, 카테고리 오분류(포럼→공모전)는 이번 범위 밖, 보고만
- 서버 배포, Firestore 데이터, 정기 배치 폴더

## 7. 검증

- `uv run pytest` 전체, `tools/validate_contracts.py`, `tools/dump_kakao_filter.py` → `dart run tool/kakao_filter_parity.dart`
- `flutter analyze --no-pub`, `flutter test --no-pub`
- 위 두 실제 글(본문은 아래 합성 버전으로 대체)로 서버 함수 결과 확인
  - 종강총회형: 계좌·예금주 가림, 학과 조건 없음, 행사일 12/14, 마감 11/27 18:00
  - 포럼형: 행사일 지난 행사, 두 번 넘기면 1건
- 릴리스 APK(`flutter clean` 후)를 에뮬레이터에 설치해 넘기기 → 결과 일정까지 캡처 `data/local/kakao_share_captures/`

## 8. 보고

- 변경 파일·요약, 검증 명령과 실제 숫자, 알림톡 665건·기존 공고 재분석 영향 건수
- 미실행 항목과 사유, `docs/handoff.md` 갱신
