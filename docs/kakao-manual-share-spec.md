# 카카오톡 공고 수동 전달 명세 (하위 에이전트용)

- 작성: 2026-11-26 (11/26 멘토링 1번 과제, 12/3 미팅 전 시연 목표)
- 상태: 팀장 결정 반영, 구현 전
- 기준 브랜치: `origin/main` 최신 (작성 시점 `5650146`). 메인 체크아웃은 쓰지 말고 새 worktree `.claude/worktrees/kakao-share`, 브랜치 `feat/kakao-share`
- 커밋·PR·배포·Firebase 변경 금지. 작업 트리에 변경만 남기고 보고한다(팀장이 확인 후 지시)

## 1. 배경

- 알림톡 자동 수집은 팀장 폰 한 대(D-034·D-036)뿐이고, 일반 사용자 폰의 알림 읽기는 정책상 막혀 있음
- 그래서 사용자가 카카오톡에서 직접 공고를 앱으로 넘기는 길을 만든다
  - 카톡 메시지 길게 누르기 → 공유 → 귀띔 (텍스트)
  - 화면 캡처 이미지 공유 → 귀띔 (기기 안 OCR → 사용자 확인·수정)
  - 앱 안 '붙여넣기' (클립보드 텍스트)
- 넘긴 공고는 분석해 분류·마감·내 조건 일치를 보여 주고, 본인 계정에만 서버 저장

## 2. 팀장 결정 (2026-11-26)

- 넘긴 공고는 **본인만** 본다. 다른 사용자 목록에 게시하지 않는다
- 서버에 저장한다. 목적은 **분류 모델 학습용**과 **개인화용**
  - 이번 PR은 저장까지만. 추천 순위에 쓰는 것(학습 기반 추천)은 SPEC P0 제외라 하지 않는다
- OCR은 Google ML Kit 글자 인식(기기 안, 무료, 한국어) 추가 승인
  - D-014에서 Gemma 비전 OCR은 없는 문장을 만들어 보류됨 → 인식 글자는 반드시 사용자가 확인·수정한 뒤 보낸다
- 아래 세부(가리기 위치, API 모양, 개인 알림 처리, 동의)는 AI 추천안으로 정했다. 바꿔야 하면 구현 전에 보고

## 3. 데이터 원칙

- 원문 이미지는 서버로 보내지 않고 저장하지도 않는다. OCR이 끝나면 버린다
- 개인정보는 **기기에서 먼저 가린다**: `apps/mobile/lib/classifier/kakao_filter.dart`의 `cleanBody`·`detectNames`·`maskPersonal` 재사용
  - 서버도 같은 파이썬 파서(`backend/collectors/mjc_kakao/parser.py`)로 한 번 더 가린 뒤 저장 (D-036 받은편지함과 같은 원칙)
- 종류 판정(`kakaoKind`)이 `personal_course`·`personal_account`·`noise`면 분석·저장하지 않고 "개인 알림이라 분류하지 않습니다" 안내
- 연도 없는 날짜는 **넘긴 날(KST)** 기준 가까운 해로 읽는다(D-019 규칙 재사용). 카톡 공유 텍스트에는 발송일이 없음 → 알려진 한계로 결정 기록에 남김
- 시간대: 사용자 입력 출처라 확인할 수 없음 → `timezone` null (SPEC §5)
- 저장 항목: 가린 본문, 입력 방법(`share_text`·`share_image_ocr`·`paste`), OCR 뒤 사용자 수정 여부, 분석 결과(Notice 모양), 분석·모델 버전, 넘긴 시각, 동의 버전
  - uid는 경로에만. 학습용 내보내기 도구는 이번 범위 밖
- 삭제: 항목 삭제, 탈퇴 시 전부, 게스트는 기존 30일 보관 정리(D-054)에 포함

## 4. 동의

- 첫 전달 때 한 번 시트로 안내·동의 (필수, 거부하면 전달 안 함)
  - 가린 글이 내 계정에 저장됨 / 분류 모델 개선에 쓰임 / 원본 이미지는 보내지 않음 / 언제든 삭제 가능
- 동의 여부·버전은 기존 상세 분석 동의와 같은 방식으로 저장 (agent-privacy-spec 참고)
- `docs/legal/privacy.md`에 수집 항목·목적·보관 기간 문구 초안 추가. 게시본 반영은 팀장 몫 → 보고에 "처리방침 게시 필요" 표시

## 5. 서버

### 5.1 API (공통 계약 변경, 팀장 승인됨)

| 메서드 | 경로 | 내용 |
|---|---|---|
| POST | `/v1/shared-notices` | 가린 글 받아 분석·저장, 결과 반환 |
| GET | `/v1/shared-notices` | 내가 넘긴 공고 목록 (최근순) |
| DELETE | `/v1/shared-notices/{id}` | 삭제 (반복 요청 안전) |

- 요청: `text`(필수, 20~5,000자), `input`(위 3종), `ocr_edited`(boolean, OCR일 때만), `consent_version`
- 응답 항목: `id`, `created_at`, `input`, `notice`(Notice 스키마), `eligibility`(기존 `backend.recommendation.evaluate` 결과 모양)
- 로그인·게스트 모두 가능. 하루 30건 상한(넘으면 `rate_limited` 오류). LLM 호출·크레딧 차감 없음
- 오류 응답은 기존 `api_error` 스키마. 화면에 상세 오류 노출 금지

### 5.2 분석

- 새 출처 `user_share` (`backend/sources.py`, `university_id` null, `timezone` null, 근거 문구 남김)
- RawNotice: `source_url` null + `source_notice_id` 생성 ID(서버 생성, 추측 불가), `published.date`는 넘긴 날
- 분석기: `KakaoAnalyzer(gemma=None)` 재사용 (규칙 분석 + 알림톡 분류 모델 + 날짜 보강). 서버에 Gemma 없음 → 애매해도 모델 답 그대로
- `build_notice`·`validate`로 근거 검증. 검증 문제가 있어도 본인에게는 보여 주되 `publication_status`는 게시 상태로 두지 않는다 (공용 목록과 섞이지 않게 저장 위치도 분리)
- 제목: 파서의 제목 규칙. 방 이름은 모르므로 빈 값

### 5.3 저장

- Firestore `users/{uid}/shared_notices/{id}`. 클라이언트 직접 접근 금지(기본 거부 규칙 유지), 서버만
- `backend/firebase_store.py`·`backend/api/deps.py`에 저장소 추가, 메모리 저장소(테스트·로컬)도 같이
- 탈퇴(`DELETE /v1/profile`)·게스트 정리에 포함

### 5.4 계약

- `contracts/shared_notice_request.schema.json`, `shared_notice_response.schema.json`, 목록 응답 스키마 추가
- `fixtures/`에 정상·비정상 샘플 (합성 텍스트만, 실제 카톡 원문 금지)
- SPEC.md: §2 범위(사용자 수동 전달 추가), §5 출처, API 표에 3줄, 버전 올림
- `docs/decisions.md`: 새 결정(번호는 파일의 가장 큰 번호 다음. #171이 D-057을 쓸 예정이므로 충돌 시 다음 번호)

## 6. 앱 (Android만)

### 6.1 받기

- `AndroidManifest.xml` MainActivity에 `ACTION_SEND` 인텐트 필터: `text/plain`, `image/*`
- 받는 코드는 `MainActivity.kt` + MethodChannel로 직접 작성 (공유 받기 패키지 추가하지 않음). 앱이 꺼져 있을 때(콜드 스타트)와 켜져 있을 때(`onNewIntent`) 모두
- 로그인 전이면 로그인 뒤 이어서 진행
- 이미지 고르기 패키지(image_picker) 추가하지 않음. 이미지는 갤러리·캡처의 공유로만 받는다

### 6.2 OCR

- `google_mlkit_text_recognition` 추가, 한국어 인식기(`TextRecognitionScript.korean`)
- APK 크기 증가량을 빌드 전후로 재서 보고
- 인식 결과는 수정 가능한 입력칸에 넣고, 위에 "인식한 글자가 틀릴 수 있습니다. 확인 뒤 보내십시오" 안내

### 6.3 화면 흐름

1. 받기 → (이미지면 인식 중 표시) → **확인 화면**: 입력칸(수정 가능), 보낼 때 가려지는 부분 미리 표시, `보내기`
2. 분석 중 → **결과 화면**: 기존 상세 화면(`report_screen.dart`) 구성 재사용. 분류·관심사·마감·지원 조건 일치, 출처 표시 "카카오톡에서 넘긴 공고", 원문 링크 없음
3. 저장 탭에 "카톡에서 넘긴 공고" 묶음 + 삭제. 저장 탭 위에 `카톡 공고 넘기기` 진입(붙여넣기 + 공유 방법 안내 한 줄)
- 신청 챙기기(D-052)에 넣을 수 있으면 넣되, 기존 구조가 공용 공고 ID 전제라면 이번 범위에서 빼고 보고
- 화면 규칙 `docs/ui-style.md`, 문구는 명사형·합쇼체(D-022, 해요체 금지)
- iOS 처리 없음 (P0 제외)

## 7. 건드리지 않을 것

- 알림톡 수집기·받은편지함(`/v1/ingest/kakao`)·정기 배치
- 분류 모델 파일·`MODEL_VERSION`, 규칙 분석기 `rules.py` (#170·#171 작업 중)
- 공용 추천(`/v1/recommendations`) 결과에 넘긴 공고 섞기
- 서버 배포, Firestore 보안 규칙 배포, 처리방침 게시본

## 8. 검증

- `uv run pytest -q -p no:cacheprovider --basetemp=data/local/tests-share` 전체 통과
- `uv run python tools/validate_contracts.py` 통과
- `apps/mobile`: `flutter analyze --no-pub`, `flutter test --no-pub` 통과
- Firestore 규칙 테스트(`tests/firestore-rules`)에 `shared_notices` 클라이언트 접근 거부 추가·통과
- 새 테스트 최소
  - 서버: 개인 알림 거부, 가리기 재확인(이름·학번·휴대폰이 저장본에 없음), 하루 상한, 남의 항목 삭제·조회 불가, 탈퇴 시 삭제, 연도 없는 날짜를 넘긴 날 기준으로 읽음
  - 앱: 공유 텍스트·이미지 받기 처리, 확인 화면 가림 미리보기, 동의 전 전송 안 함
- 실기기(S25 Ultra 또는 에뮬레이터) + 로컬 서버(`backend/api/local.py`)
  - 실제 카톡 학교 채널 메시지 텍스트 공유 1건, 캡처 공유 1건, 붙여넣기 1건 → 결과 화면 캡처를 `data/local/kakao_share_captures/`(git 제외)에
  - 캡처 OCR 정확도: 학교 채널 캡처 5장으로 인식 글자와 실제 글을 비교해 마감일·제목이 맞았는지 표로
  - 라이트·다크, 글자 2배
- 실행 못 한 검증은 "미실행"과 사유

## 9. 보고 형식

- 변경 파일과 요약
- 검증 명령과 실제 결과(숫자)
- APK 크기 증가량, OCR 5장 표
- 남은 일: 처리방침 게시, 서버 배포(새 API), 보안 규칙 배포, APK 빌드 버전
- `docs/handoff.md` 갱신
- 커밋·PR 하지 않음
