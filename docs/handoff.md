# 인수인계 (handoff)

마지막 갱신: 2026-10-17

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

[다음 작업 명세](next-work-spec.md)에 작업별 담당 제안·산출물·선행 조건·완료 기준과 계약 결정 질문을 정리했습니다(2026-10-16). 명세 작성만 완료했으며 기술·출처·계약 합의나 구현은 아직 진행하지 않았습니다. 먼저 T1의 SPEC·역할 합의안을 검토하고, T2~T6을 작업별로 진행합니다.

**T1 진행 상태 (2026-10-17):** [결정 기록](decisions.md)의 D-001~003을 팀장이 결정했습니다. 상태는 `팀장 결정 (팀원 확인 전)`이며, 팀원 확인란은 비어 있습니다.

- D-001: SPEC v0.1을 제안대로 개발 준비 기준으로 채택. SPEC 상태 문구 변경은 별도 PR.
- D-002: 안 B. 수집 파이프라인·배포는 팀장, 팀원은 어댑터 1개·Flutter 화면. 출처 허가 대기 중 팀원은 샘플 기반 화면 선행. Firebase는 팀장 계정 소유(생성은 별도 요청 전까지 안 함). 재조정은 필요할 때. 팀원 개발 환경 준비 여부는 미확인(T3에서 확인).
- D-003: 파일 경계·공동 파일 절차를 합의안대로 채택.

다음 단계: 팀원 확인을 받아 `확정`으로 바꾸고, T2(첫 출처 확인·신청)·T3(개발환경·인증·서버)를 진행합니다.

**T3 진행 상태 (2026-10-17):** [D-004](decisions.md)에 팀장 결정을 기록했습니다(팀원 확인 전). Flutter 3.47.7/Dart 3.13.5, Python 3.12 + uv, Google 로그인, Cloud Run(API), 팀장 PC 로컬 배치 + Ollama 평가, Firebase dev/prod 분리, 에뮬레이터 개발 + 실기기 시연입니다. 클라우드 리소스는 생성하지 않았습니다. 팀장 PC의 Flutter 업그레이드(현재 3.47.2)와 Android 라이선스 수락은 아직 실행하지 않았습니다. 수집 운영값은 T2 후 10/24까지 공동으로 정합니다.

**T2 진행 상태 (2026-10-17):** [출처 검토 기록](source-review.md)을 작성했습니다. www robots.txt는 전체 허용, mpu는 `Disallow: /`, 이용약관·저작권정책 페이지는 없습니다("All Rights Reserved"). 그래서 수집·저장·재표시·LLM·첨부 이용은 **미확인**입니다. P0는 공지사항(menu_idx=66) 1개로 시작하고, 어댑터는 게시판 설정으로 확장할 수 있게 만듭니다. 이용 허락 요청 문안은 초안만 있고 **발송하지 않았습니다**(팀장 발송 예정). 허락 확인 전에는 실제 수집을 활성화하지 않습니다.

**T4 진행 상태 (2026-10-17):** [D-005](decisions.md)에 계약 미정 사항 10건의 팀장 결정을 기록했습니다(팀원 확인 전). 게시일·마감일 날짜 객체 통일, `explicitly_unrestricted`, 학교 접두사 코드, 고정 판정·이유 코드, 시기 점수 구간, 추천 `mode`, 오류·목록 틀입니다. SPEC 변경이 필요하며, T5 PR에서 SPEC·스키마·샘플과 함께 갱신합니다. 학과 코드값과 관심사·직무 사전은 아직 정하지 않았습니다.

이 브랜치(`docs/development-preparation-spec`)는 아직 병합되지 않은 `docs/github-setup-handoff`(8051262) 위에서 시작했습니다. 해당 PR을 먼저 병합하거나 이 PR에 함께 포함됨을 확인해야 합니다.

| 작업 | 담당 | 목표일 |
|---|---|---|
| SPEC.md 검토·합의 | 공동 | 10/18 |
| 첫 출처 선정, 수집·재사용 조건 확인·신청, 실패 시 대체 출처 (검토 완료, 허락 요청 미발송) | 팀장 | 10/18 |
| Flutter·Dart·Python 버전과 의존성 고정 (D-004 팀장 결정) | 공동 | 10/18 |
| 인증 방식·서버 실행 환경 결정 (D-004: Google 로그인, Cloud Run) | 팀장 | 10/18 |
| 공통 ID·태그·학과/직무 사전, `contracts/` JSON Schema 작성 | 팀장, 팀원 검토 | 10/18 |
| 샘플 JSON(`fixtures/`) 작성, 역할 경계 합의 | 공동 | 10/18 |
| `docs/decisions.md`에 위 결정 기록 (D-001~003 팀장 결정 완료, 팀원 확인 전) | 팀장 | 결정 시 |

10/19~23은 시험주간으로 신규 기능 필수 일정이 없습니다. 승인 답변·차단 사항만 확인합니다.

## 버전 확정 후 할 일

- 실제 실행 가능한 검사(Flutter analyze/test, Python test)가 생기면 CI 추가 검토.
- 결정된 환경변수를 `.env.example`에 이름·설명으로 추가.

## 미결·차단 사항

- 명지전문대 공개 게시판 이용 허락 여부 미확인. 요청 문안 초안은 `docs/source-review.md` 부록에 있으며 아직 발송하지 않았습니다.
- 대회 마감일 공식 공지 변경 여부 팀장 확인 필요.
