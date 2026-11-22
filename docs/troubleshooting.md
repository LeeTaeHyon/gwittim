# 트러블슈팅 모음

- 목적: 한 번 겪은 문제와 해결법을 한곳에. 같은 문제를 다시 만나면 여기부터 찾음
- 형식: 증상 → 원인 → 해결. 새 문제를 풀면 해당 절에 한 줄 추가
- 비밀값(키·토큰)은 여기에도 적지 않음

## 1. LLM·맞춤 에이전트

| 증상 | 원인 | 해결 |
|---|---|---|
| 리포트에 `not_met`, `enrollment_status`, `null` 같은 영어 코드가 그대로 나옴 (2026-11-22, DeepSeek) | 모델에 보내는 자료가 코드 그대로라 모델이 옮겨 씀. 지시문만으로는 완전히 못 막음 | 세 겹: ① 보내기 전에 값·칸 이름을 한국어로(`prompt.build_messages`) ② 지시문에 코드 금지 ③ 받은 리포트의 알려진 코드를 한국어로 치환(`prompt.scrub_codes`, 주소 안은 제외, 바꾼 횟수만 로그). 치환 횟수가 늘면 지시문 점검 (#127) |
| DeepSeek 응답 `content`가 공백뿐 | `json_object` 모드에서 JSON으로 인식 못 한 출력은 공백으로 바뀜 | 지시문에 'json' 낱말과 형식 예시가 있어야 함. 공백이면 `ReportFormatError` → 환불 |
| DeepSeek 출력 토큰이 리포트 길이보다 훨씬 많음(약 1,800~3,700) | `reasoning_effort: low`여도 생각 토큰이 출력에 포함 | `none`(생각 끔)으로 변경: 출력 약 700토큰, 0.9원, 5초 (2026-11-22 비교) |
| 리포트에 '조건을 모두 찾았는지 여부는 아니요' 같은 입력 칸 이름이 그대로 나옴 | 예/아니요 칸을 모델이 문장에 옮김 | 예/아니요 칸 대신 뜻을 담은 문장('참고')으로 보내고, 지시문에 칸 이름을 옮기지 말라고 적음 |
| 생각을 끈 뒤 리포트가 '~한다', '~있다'(평서형)로 끝남 | 지시문의 '명사형 또는 합쇼체'만으로는 평서형을 막지 못함 | 지시문에 예시를 붙여 '합쇼체(~입니다) 또는 명사형(~임)', '평서형(~이다, ~한다) 금지'로 명시 |
| 요약에 '3월부터 5개월'이 있는데 모델이 활동 기간을 모른다고 함 | 활동 기간을 못 뽑은 공고에 '활동 기간: 미상'을 보내 요약보다 우선함 | 못 뽑은 칸은 '미상'으로 보내지 않고 뺌. 마감처럼 꼭 필요한 칸만 '미상'으로 보냄 |
| DeepSeek 비용 기록이 시간마다 다름 | 피크(평일 한국 10~13시·15~19시)는 단가 2배 | `llm.deepseek_prices`가 호출 시각으로 계산. 중국 공휴일 할인은 반영 안 함(높게 잡힘) |
| Haiku API 리포트가 중간에 잘림 | Haiku 5.5는 생각이 기본으로 켜져 `max_tokens` 안에서 생각 토큰을 먼저 씀 | `effort: low`, `max_tokens` 8000 (#121) |
| Cloud Run에서 합성 리포트가 크레딧을 차감하며 나갈 뻔함 | 기본 제공자가 `fake` | `K_SERVICE`가 있으면 `fake`는 "준비 중"으로 답함 (#121) |
| `claude -p`(cli 제공자)에 공고 본문 속 지시문이 로컬 파일을 읽게 할 수 있음 | CLI가 도구·MCP·CLAUDE.md를 불러옴 | `--tools "" --strict-mcp-config --disable-slash-commands --no-session-persistence`, 빈 임시 폴더에서 실행 (#106) |
| `uv run` 아래에서 Codex CLI가 '액세스가 거부되었습니다'로 실패 | .venv 파이썬 환경과 Codex 앱 서버 충돌 | `tools/llm_compare.py`는 시스템 파이썬(`C:\Python314\python.exe`)으로 실행 |
| `uv run`(.venv 파이썬)에서 부른 opencode가 `FileSystem.open (...opencode.log)`로 실패 | .venv 파이썬 실행기 아래에서만 생김. 환경변수·샌드박스와 무관(같은 명령이 셸·바탕 파이썬에서는 됨) | 바탕 파이썬 + `PYTHONPATH=.venv/Lib/site-packages`로 실행 (예: `C:/AI/Anime-Llasa/Python312/python.exe tools/llm_board_read.py ...`) |
| opencode에 공고 페이지를 넘길 때 페이지 속 문장이 도구(파일 읽기·명령)를 쓰게 할 수 있음 | opencode run은 기본으로 도구가 켜진 에이전트 | `OPENCODE_CONFIG_CONTENT`로 `permission: {"*": "deny"}`와 도구 전부 false, 빈 임시 폴더에서 실행. 입력 토큰도 약 12,500 → 3,200으로 줄어듦 |
| 사용자 환경변수로 등록한 키가 이미 열린 터미널·세션에서 안 보임 | 환경변수는 새로 연 프로세스부터 적용 | 새 터미널을 열거나, 스크립트에서 레지스트리(`HKCU\Environment`)를 읽어 자식 프로세스에만 넘김. 키 값은 출력하지 않음 |

## 2. 로컬 서버·실호출 시험

| 증상 | 원인 | 해결 |
|---|---|---|
| 로그에 `gwittim.agent.llm` 줄(토큰·비용)이 안 보임 | uvicorn은 자기 로거만 설정 | `logging.basicConfig(level=logging.INFO)` 후 `uvicorn.run(app)`을 같은 파이썬에서 실행 |
| 스크립트 안에서 `uv run`을 다시 부르면 `Failed to initialize cache ... 액세스가 거부` | 실행 환경(샌드박스)에서 uv 캐시 폴더 쓰기 제한 | 바깥 `uv run`의 파이썬(`sys.executable`)으로 자식 프로세스 실행 |
| `data/local/` 아래 스크립트에서 `ModuleNotFoundError: backend` | 스크립트 폴더가 경로 기준이 됨 | `sys.path.insert(0, 저장소 루트)` |
| `%TEMP%`에 파일 쓰기 `PermissionError` | 실행 환경의 쓰기 제한 | 작업 폴더의 `data/local/`(git 제외)에 씀. 끝나면 지움 |
| 실제 학교 공고로 시험하고 싶음 | `backend.api.local`은 합성 fixtures만 씀 | `data/local/notices.json`에서 공고 1건을 `InMemoryNotices`에 넣어 `create_app`. 프로필은 합성값만 |

## 3. git·worktree·PR

| 증상 | 원인 | 해결 |
|---|---|---|
| 메인 폴더가 남의 브랜치·미커밋 상태 | 사용자나 다른 세션이 작업 중일 수 있음 | 작업 전 `git branch --show-current`, `git status --short`. 내 작업은 `.claude/worktrees/<이름>`에 worktree로 |
| `git worktree remove`가 `Permission denied`·`Filename too long` | 열린 파일, Windows 경로 길이 | `git worktree prune`으로 등록만 해제, 폴더는 `Remove-Item -Recurse -Force \\?\<경로>` |
| worktree에서 `flutter run` 실패(`google-services.json` 없음) | git 제외 파일이라 worktree에 안 따라옴 | 메인 폴더에서 복사. 커밋하지 않음 |
| push 직후 `gh pr merge`가 반영 안 됨 | GitHub 쪽 최신 커밋 반영 지연 | `gh pr view --json headRefOid`로 커밋이 맞는지 확인 후 다시 |
| 병합 전 검증 순서 | | 브랜치에 origin/main 합치기 → `uv run pytest -q` → `PYTHONIOENCODING=utf-8 uv run python tools/validate_contracts.py` → `flutter analyze` → `flutter test` |
| git stash 충돌 위험 | stash는 모든 worktree·세션이 공유 | 맨 `git stash pop` 금지. 임시 커밋을 쓰거나 이름 붙인 stash를 SHA로 적용 |

## 4. 셸·파일 편집 (Windows)

| 증상 | 원인 | 해결 |
|---|---|---|
| bash heredoc 안 파이썬에서 `unexpected EOF`, `\r`·`\n`이 엉뚱하게 해석 | 따옴표·백슬래시 겹침 | 파이썬 코드는 파일로 따로 쓰고 실행. 백슬래시가 필요하면 `chr(92)` |
| Dart 파일에 보이지 않는 문자(`\u2060`, NBSP)가 그대로 들어감 | 편집 도구가 문자 자체를 삽입 | 소스에는 `'\u2060'` 같은 이스케이프로 씀 |
| `scripts/run_batch.ps1` 편집 뒤 한글 깨짐·실행 오류 | 이 파일은 UTF-8 BOM + CRLF | 편집 후 BOM·CRLF 유지 확인 |
| 백그라운드 작업이 10분에 끊김 | 도구의 백그라운드 시간 상한 | 긴 작업은 나눠 돌리거나, 핫 리로드는 표준 입력 파일로 명령 전달 |
| 한글 출력이 깨짐 | Windows 콘솔 인코딩 | `PYTHONIOENCODING=utf-8` |

## 5. 앱·기기

| 증상 | 원인 | 해결 |
|---|---|---|
| `flutter drive` 뒤 폰에서 앱이 지워져 로그인이 날아감 | drive는 끝나면 앱 삭제 | 반드시 `--keep-app-running` |
| 실기기에서 `traceAction`·`watchPerformance`가 VM 서비스 연결 실패 | 기기 쪽 연결 문제 | `SchedulerBinding.addTimingsCallback`으로 FrameTiming 직접 수집 |
| `adb install` 권한 오류 | 다중 사용자 기기 | `adb install -r --user 0` |
| 큰 글꼴(2.0배)에서 제목이 단어 중간에서 끊김 | 한글은 글자 단위 줄바꿈 | `format.dart`의 `keepAll()`(단어 사이 word joiner) (#119) |
| 화면 전체를 흐리게 겹치는 전환이 끊김 | GPU 그리기 20~50ms | 작은 요소 페이드만 사용 (`ui-style.md`) |

## 6. 문서·PDF

| 증상 | 원인 | 해결 |
|---|---|---|
| HTML → PDF 변환 도구 없음(pdftoppm·PIL 없음) | | Chrome 헤드리스: `chrome.exe --headless=new --allow-file-access-from-files --no-pdf-header-footer --print-to-pdf=<out> file:///...html` |
| 확대 점검 | | 같은 HTML을 `--screenshot --force-device-scale-factor=2`로 찍음 |
