# 공고 상세의 원문 포스터 (명지 게시판 1차)

2026-11-24 · 구현용 명세 · 받는 사람: 구현 에이전트

- 근거: 팀장 결정(2026-11-24) "명지 게시판 공고만 대상으로 포스터 사진 추가를 진행. 포스터 주소는 원문 바뀜 해시에서 제외"
- 초안: 메인 폴더 `docs/notice-detail-poster-spec.md`(검토용, 미커밋). 이 문서가 그 초안을 대신한다
- 새 세션은 먼저 메인 폴더의 `docs/agent-onboarding.md`를 읽고 작업 상태를 다시 확인한다. 온보딩 원본은 메인 체크아웃에 있다.
- 공통 계약 변경이다(AGENTS.md §3). SPEC·스키마·샘플·생산자·소비자를 한 PR에서 고친다. **커밋·PR은 하지 않는다**(아래 §9)

## 1. 목표

학생이 공고 상세에서 원문 포스터 한 장을 보고, 눌러서 확대해 읽을 수 있게 한다. 대상 출처는 명지전문대 게시판(`mjc_www_*` 4개)만이다.

## 2. 측정 (2026-11-24, 게시된 명지 게시판 공고 201건의 상세 페이지를 다시 받아 셈)

- 결과 파일: `data/local/poster_count.json`(git 제외, 공고마다 본문 이미지 src·alt)
- 저장 표본을 공고 ID별로 다시 집계한 결과, 본문 이미지가 한 장 이상인 공고는 152/201(75.6%)이다. 아래 후보 수는 이미지 내용에 대한 육안 판정 없이 URL 규칙으로 센 값이다.
- 아래 §3 후보 규칙(편집기 이미지, jpg·jpeg·png·gif·webp)에 맞는 공고는 **145/201 (72.1%)**이다.

| 게시판 | 공고 | 후보 있음 |
|---|---|---|
| mjc_www_job | 85 | 83 (98%) |
| mjc_www_notice | 60 | 45 (75%) |
| mjc_www_scholarship | 34 | 16 (47%) |
| mjc_www_work | 22 | 1 (5%) |

- 표본에서 모집 중(`lifecycle=open`)인 공고 32건 중 28건(87.5%)에 후보가 있다.
- 본문 이미지 수는 공고당 1장 121건, 2장 26건, 3장 이상 5건이다. 서로 다른 주소로 같은 안내를 게시할 수 있다.
- 추천채용 공고 9건은 첫 후보의 대체텍스트에 ‘접수 전 유의사항’과 ‘이력서’가 함께 나온다. 9건 모두 뒤에 다른 후보가 있다. 예를 들어 한독모터스 채용 공고(`n_3356db1408e568971c16`)는 두 번째 이미지의 대체텍스트가 비어 있다. 첫 장 규칙을 그대로 쓰면 공통 지원 안내가 먼저 보인다. 실제 모집 포스터 비율은 이 집계로 확정할 수 없다.
- 이미지 서버 `https://mjcms.mjc.ac.kr/crosseditor/binary/images/…`: Referer·쿠키 없이 바로 200, 170~390KB. `mjcms.mjc.ac.kr/robots.txt`는 없음(404), `www.mjc.ac.kr/robots.txt`는 `Allow: /`
- 제외할 것: 첨부 다운로드 주소로 본문에 박힌 이미지(`…fileDown…attach_idx=…`, PNG 약 15MB) 8장, BMP(약 4MB) 3장

## 3. 포스터 고르기 (수집기 `backend/collectors/mjc_www/parser.py`)

- `div#divMemo` 안 `<img>`를 원문 순서대로 본다. 주석 안 마크업은 무시(지금 파서와 같음)
- 후보: `src`를 상세 페이지 주소 기준 절대 주소로 바꾼 뒤
  - 스킴이 `https`이고 호스트가 `mjcms.mjc.ac.kr` 또는 `www.mjc.ac.kr`
  - 경로에 `/crosseditor/binary/images/`가 있음
  - 확장자가 jpg·jpeg·png·gif·webp(대소문자 무시)
- 후보 중 첫 장 하나만 `poster_url`. 후보가 없으면 필드를 두지 않는다
- 크기·내용으로 거르지 않는다(이미지를 받지 않음). OCR 하지 않는다
- 기존 대체텍스트 읽기(D-014, `alts`, `body_image_text_count`)는 그대로 둔다

## 4. 데이터 전달

- 수집기: `RawNotice.source_fields.poster_url`(문자열, 선택). `backend/collectors/mjc_www/adapter.py`의 `to_raw_notice`
- **해시 제외**: `backend/collectors/common/identity.py`의 `content_hash`가 `source_fields`에서 `poster_url`을 뺀 값으로 계산한다
  - 같은 수정을 `contracts/raw_notice.schema.json`의 `content_hash` 설명과 SPEC §5 RawNotice 설명에 반영
  - 이유: 포스터만 바뀐 것으로 버전·변경 필드·재분석·저장 공고 '마감 변경'이 생기지 않게. 기존 공고의 해시도 그대로 유지된다
- **해시가 같아도 포스터는 갱신**: 해시가 같으면 파이프라인이 원문을 건너뛰거나 처음 받은 raw를 그대로 쓰는지 확인한다(`backend/analysis/notice.py`의 `build_notice` 주석 "원문이 그대로면 raw는 처음 받은 것"). 그렇다면 해시가 같아도 새 수집의 `poster_url`로 게시본의 `poster_url`을 바꾸거나 지운다. 이때 `notice_version`, `changed_fields`, 분석은 건드리지 않는다
- **기존 공고 채우기**: 정기 배치(`backend/batch.py`)가 이미 받은 공고의 상세를 다시 받는지 확인한다(86~102행 근처 수집 창 로직). 다시 받지 않으면 게시된 명지 게시판 공고 전체에 대해 한 번 상세를 받아 `poster_url`만 채우는 방법(배치 옵션 또는 일회 도구)을 만들고, 로컬에서만 시험한다. 운영 데이터에 실제로 돌리는 것은 하지 않는다(§9)
- 게시: `Notice.poster_url`(문자열, 선택). `contracts/notice.schema.json`에 추가(`additionalProperties: false`라 필수). 형식 `uri`, 값이 없으면 필드 생략. `null`도 앱에서는 없음으로 처리
- 목록 응답(추천·검색·저장 목록의 공고 요약)에는 넣지 않는다. `GET /v1/notices/{notice_id}` 상세 응답에만
- 숭의·위비티·콘테스트코리아·알림톡 수집기는 바꾸지 않는다(필드 없음 = 포스터 없음)
- `schema_version` 올릴지는 SPEC의 버전 규칙을 따른다(선택 필드 추가)
- 샘플: `fixtures/`의 명지 게시판 Notice·RawNotice 샘플 중 하나에 `poster_url` 추가, 없는 샘플도 그대로 유효해야 함

## 5. 앱 (`apps/mobile`)

- 모델: `lib/data/models.dart`의 `Notice`에 `posterUrl`(nullable). `fromJson`에서 없거나 `null`이면 null
- 상세(`lib/ui/report_screen.dart`) 배치: 제목·출처·게시일 → 요약 → 원문 재확인·변경 안내 → **포스터** → 지원 전 체크리스트. 요약·안내가 없으면 그 칸만 건너뛴다
- 미리보기
  - 본문 폭 안에서 원본 비율 그대로 전체가 보이게(잘라내지 않음), 최대 높이 180, 가운데 정렬
  - 아래에 `zoom_in_rounded` 18 + '포스터 크게 보기'(14/600 `sub`). 이미지와 문구 전체가 한 누름 영역(높이 48 이상), 모양은 `GwCard`처럼 반지름 20 안에서 `InkWell`
  - 화면 읽기 이름 '포스터 크게 보기'(버튼). 이미지 자체는 읽지 않음
  - 받는 중: 같은 크기의 스켈레톤(`lib/ui/skeleton.dart` 방식). 회전 원 금지(ui-style §6)
  - 실패(404·시간 초과·디코딩 실패)나 `posterUrl == null`: 이미지·문구·위아래 여백을 통째로 숨김. 오류 문구 없음
  - 홈·공고 탭·저장함·달력 목록에서는 요청하지 않는다
- 확대 화면
  - `gwRoute`로 여는 새 화면, 바탕 검정, `InteractiveViewer`(최소 1배, 최대 5배)로 처음엔 전체가 보이게 맞춤
  - 오른쪽 위 닫기(✕, `GwTopBar` 규칙과 같은 '닫기' 이름), Android 뒤로 가기도 닫힘. 닫으면 상세의 스크롤 위치 그대로
  - 실패하면 가운데 짧은 문구 '포스터를 불러오지 못했습니다.' + 닫기만
- 새 라이브러리 추가 금지. `Image.network`와 Flutter 기본 캐시만 쓴다
- 색은 `context.gw` 토큰만, 라이트·다크 둘 다 확인. 큰 글자(1.3배 상한)에서 넘치지 않게 `test/text_scale_test.dart`에 포스터 있는 상세를 넣는다
- `docs/ui-style.md`에 포스터 미리보기·확대 화면 규칙을 더한다

## 6. 건드리지 않을 것

- 지원 자격·마감 판정, 분석 규칙(rule-*), 추천 순서
- 다른 출처 수집기, 알림톡, 외부 공고 찾기
- 이미지 저장·복제·이미지 서버, 썸네일 만들기
- 메인 폴더의 미커밋 문서(`docs/final-prep-todo.md`, `docs/stage2-results.md`, `docs/*-spec.md` 초안)
- 서버 배포, Firestore 운영 데이터, 정기 배치(`Gwittim-batch`) 갱신

## 7. 작업 순서

1. 계약: SPEC §5(RawNotice·Notice), `contracts/raw_notice.schema.json`, `contracts/notice.schema.json`, `fixtures/` 샘플, 계약 검사 통과
2. 해시 제외(`identity.py`)와 테스트: `poster_url`만 다른 두 raw의 해시가 같다
3. 수집기 파서·어댑터와 테스트: §3 규칙(편집기 이미지 첫 장, 첨부 다운로드·BMP·외부 호스트 제외, 상대 주소 → 절대 주소, 후보 없으면 필드 없음)
4. 게시: 해시가 같아도 `poster_url` 갱신·삭제, 버전·변경 필드 그대로. 테스트
5. 기존 공고 채우기 경로(§4)와 로컬 시험
6. 서버 상세 응답에 `poster_url`, 목록 응답에는 없음. 테스트
7. 앱 모델·상세 미리보기·확대 화면·테스트·ui-style
8. 실제 데이터로 확인: `data/local/notices.json`의 명지 게시판 공고에 이번 수집기로 받은 `poster_url`을 붙여 로컬 서버를 띄우고 에뮬레이터에서 확인(방법은 아래 §8). 운영 서버는 쓰지 않는다

## 8. 검증

- `uv run pytest -q` 전체 통과, 계약 검사 통과(기존 명령은 `docs/deploy-runbook.md`·`README` 참고)
- `cd apps/mobile && flutter analyze && flutter test` 전체 통과
- 수집기 시험: 명지 게시판 상세 몇 건(채용·일반 공지·장학 각 1건 이상, 포스터 없는 근로 1건)을 받아 `poster_url`이 §2 측정 파일(`data/local/poster_count.json`)의 첫 후보와 같은지 확인. 요청 간격 0.5초 이상
- 에뮬레이터(`chzzk_pixel`) 확인
  - 로컬 서버: `data/local/notices.json`을 `InMemoryNotices`에 올리고 개발 토큰으로 띄우는 방법은 `backend/api/local.py`와 같게, 결과 파일은 scratchpad가 아니라 git 제외 폴더에
  - `flutter run -d emulator-5554 --dart-define=GWITTIM_API_BASE=http://10.0.2.2:8765/ --dart-define=GWITTIM_DEV_TOKEN=dev-token`
  - worktree에는 `android/app/google-services.json`이 없으니 메인 폴더에서 복사(git 제외 확인)
  - 볼 것: 세로 긴 포스터·가로 포스터, 포스터 없는 공고, 이미지 주소를 일부러 틀린 공고(실패 시 영역 없음), 확대 후 닫으면 원래 위치, 라이트·다크, 글자 2배 설정
- 원문 바뀜 확인: 같은 공고를 `poster_url`만 바꿔 두 번 게시하면 `notice_version`·`changed_fields` 그대로, 포스터만 바뀜

## 9. 하지 말 것·보고

- 커밋·푸시·PR 금지. worktree에 변경만 남긴다
- 서버 배포, 운영 Firestore 쓰기, 정기 배치 갱신 금지
- 비밀정보 출력·커밋 금지(AGENTS.md §4)
- 끝나면 보고: 바꾼 파일과 요약, 실행한 검증 명령과 결과(못 한 것은 '미실행'과 이유), 에뮬레이터 스크린샷 경로, 기존 공고 채우기 방법과 운영에서 돌릴 때 필요한 절차, 남은 문제
