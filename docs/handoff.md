# 인수인계 (handoff)

마지막 갱신: 2026-10-16

## 현재 상태

- 저장소 초기 설정 완료: SPEC.md(v0.1 제안 초안), README.md, AGENTS.md, .gitignore, .env.example, PR 템플릿.
- 앱·백엔드 코드 없음. Firebase 프로젝트 미생성. 서버 실행 환경 미선정. CI 없음.
- 확정된 환경변수 없음.
- SPEC.md는 팀 합의 전 초안입니다. 합의 후 기준 버전으로 사용합니다.

## GitHub 초기 설정 결과 (2026-10-16)

- 저장소: https://github.com/LeeTaeHyon/gwittim — 비공개(`PRIVATE`), 기본 브랜치 `main`.
- 인증 계정: `LeeTaeHyon`. `gh auth status` 성공. 계정 API의 `plan`은 null로 반환되어 요금제 이름을 확정하지 않았습니다.
- 동명 저장소 조회에서 HTTP 404를 확인한 뒤 새 저장소를 생성했습니다.
- `.github/pull_request_template.md`를 작업 지시서 원문대로 생성했습니다.
- 초기 커밋 `23f3b06`을 `main`에 최초 푸시했습니다. 포함 파일은 `SPEC.md`, `README.md`, `AGENTS.md`, `.gitignore`, `.env.example`, `.github/pull_request_template.md`, `docs/handoff.md`의 7개뿐입니다.
- `SPEC.md`와 `.env.example` 등 기존 파일의 내용은 초기 커밋에서 변경하지 않았습니다. `Claude outputs/`는 추적하지 않는 로컬 참고 자료로 남겨 두었습니다.
- `protect-main` ruleset 생성과 조회 모두 HTTP 403으로 실패했습니다. 강제 푸시 금지·브랜치 삭제 금지·PR 및 승인 필수 설정은 적용되지 않았습니다. 브랜치 API에서도 `protected: false`를 확인했습니다.
- 실패 응답 원문(생성·조회 공통):

  ```json
  {"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","documentation_url":"https://docs.github.com/rest/repos/rules#create-a-repository-ruleset","status":"403"}
  ```

  조회 실패의 `documentation_url`은 `https://docs.github.com/rest/repos/rules#get-all-repository-rulesets`입니다.

- 비공개 상태를 유지했습니다. 팀원은 초대하지 않았습니다.
- 개인 저장소 협업자는 쓰기 권한을 받으므로, 현재 설정에서는 팀원의 `main` 직접 푸시를 기술적으로 막을 수 없습니다. README·AGENTS.md의 PR 경유 규칙으로 운영합니다. 보호를 강제하려면 팀장이 Pro 업그레이드 또는 공개 전환 여부를 결정해야 합니다.
- 이번 결과 기록은 `docs/github-setup-handoff` 브랜치에서 PR로 검토·병합합니다.

### 실행한 검증

- `gh repo view LeeTaeHyon/gwittim --json url,visibility,defaultBranchRef`: `PRIVATE`, `main`, 저장소 URL 확인.
- `gh api 'repos/LeeTaeHyon/gwittim/git/trees/main?recursive=1'`: 원격 파일이 지정된 7개와 일치함을 확인.
- `gh api repos/LeeTaeHyon/gwittim/branches/main`: 초기 커밋 일치 및 `protected: false` 확인.
- `gh api -X POST repos/LeeTaeHyon/gwittim/rulesets --input -`, `gh api repos/LeeTaeHyon/gwittim/rulesets`: 모두 위 HTTP 403 응답 확인.
- PowerShell로 지시서의 템플릿 블록과 생성 파일 비교: 줄바꿈 차이를 제외한 원문 일치.
- `git status`, `git diff --staged`: 초기 커밋의 7개 파일 전체 검토. 비밀정보·실제 개인정보 파일 없음.
- `git diff --check`: 통과.
- 앱·백엔드 빌드 및 테스트: 미실행. 아직 실행할 코드가 없습니다.

### 요청자가 할 일

- 이번 인수인계 기록 PR의 원문·실행 결과를 확인한 뒤 병합합니다.
- 팀원 GitHub 아이디 전달 후 협업자로 초대하고, 초대 수락을 확인합니다.
- 보호 설정 강제가 필요하면 Pro 업그레이드 또는 공개 전환 여부를 결정합니다.

## 다음 작업 (SPEC §3 개발 준비: 10/16~18, §12 착수 전 결정)

| 작업 | 담당 | 목표일 |
|---|---|---|
| SPEC.md 검토·합의 | 공동 | 10/18 |
| 첫 출처 선정, 수집·재사용 조건 확인·신청, 실패 시 대체 출처 | 팀장 | 10/18 |
| Flutter·Dart·Python 버전과 의존성 고정 | 공동 | 10/18 |
| 인증 방식·서버 실행 환경(Cloud Run / Cloud Functions) 결정 | 팀장 | 10/18 |
| 공통 ID·태그·학과/직무 사전, `contracts/` JSON Schema 작성 | 팀장, 팀원 검토 | 10/18 |
| 샘플 JSON(`fixtures/`) 작성, 역할 경계 합의 | 공동 | 10/18 |
| `docs/decisions.md` 생성 후 위 결정 기록 | 팀장 | 결정 시 |

10/19~23은 시험주간으로 신규 기능 필수 일정이 없습니다. 승인 답변·차단 사항만 확인합니다.

## 버전 확정 후 할 일

- 실제 실행 가능한 검사(Flutter analyze/test, Python test)가 생기면 CI 추가 검토.
- 결정된 환경변수를 `.env.example`에 이름·설명으로 추가.

## 미결·차단 사항

- 명지전문대 공개 게시판 이용 허락 여부 미확인.
- 대회 마감일 공식 공지 변경 여부 팀장 확인 필요.
