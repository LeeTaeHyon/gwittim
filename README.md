# 귀띔 (Gwittim)

학생이 몰랐던 교내외 기회(공고)를 발견하고, 지원 조건과 원문을 확인한 뒤 저장할 수 있는 Android 앱입니다.

핵심 흐름: 공고 수집 → 정규화·분석 → 검증·저장 → 지원 조건 비교 → 추천 → 상세·원문 확인 → 저장

상세 목표·범위·데이터 계약·처리 규칙은 [SPEC.md](SPEC.md)가 기준입니다.

## 현재 준비 상태 (2026-10-16)

| 항목 | 상태 |
|---|---|
| 공통 개발 명세 (SPEC.md v0.1) | 제안 초안. 팀 합의 전 |
| 협업 규칙 (AGENTS.md, PR 템플릿) | 작성됨 |
| 앱 (Flutter) | 미착수 |
| 수집·분석·추천 (Python) | 미착수 |
| 공통 계약 (`contracts/` JSON Schema) | 미작성 |
| Firebase 프로젝트 | 미생성 |
| 서버 실행 환경 (Cloud Run / Cloud Functions) | 미선정 |
| 첫 수집 출처·이용 허락 | 확인 전 |
| Flutter·Dart·Python 버전 | 미고정 |
| CI | 없음 (실행 환경 확정 후 추가) |

아직 빌드하거나 실행할 코드는 없습니다. 다음 작업은 [docs/handoff.md](docs/handoff.md)를 참고하세요.

## 기술 구성 (SPEC 기준안)

- 앱: Flutter / Dart, Android
- 데이터·인증: Firebase Authentication / Firestore
- 수집·분석: Python 배치
- 추천: Python 순수 로직 + 인증된 서버 API
- LLM: 교체 가능한 분석 인터페이스, 로컬 우선 평가

## 저장소 구조 (예정)

```text
SPEC.md                  공통 개발 명세
AGENTS.md                사람·AI 에이전트 공통 작업 규칙
apps/mobile/             Flutter 앱
backend/collectors/      수집 어댑터
backend/analysis/        정규화·LLM 추출·검증
backend/recommendation/  조건 비교·추천
backend/api/             서버 API
contracts/               JSON Schema (공통 계약)
fixtures/                샘플 데이터
docs/decisions.md        주요 결정 기록
docs/handoff.md          현재 상태와 다음 작업
```

폴더는 실제 작업이 시작될 때 생성합니다.

## 협업 방법

2인 팀입니다. 팀장이 전체 의사결정과 통합·병합을 담당합니다.

1. `main`에 직접 푸시하지 않습니다. 최신 `main`에서 기능 브랜치를 만듭니다.
   - 이름 예: `feat/collector-mjc`, `feat/mobile-feed`, `fix/deadline-parse`, `docs/contracts`
2. 작은 단위로 커밋하고 브랜치를 푸시합니다.
3. `main` 대상 PR을 열고 PR 템플릿(변경 목적·내용·검증 결과·미완료 사항)을 채웁니다.
4. 팀장이 검토 후 병합합니다. 병합된 브랜치는 정리합니다.
5. 공통 계약(SPEC.md, `contracts/`, 공통 사전) 변경은 이유와 영향을 먼저 공유하고, 문서·스키마·샘플·소비 코드를 같은 PR에서 갱신합니다.
6. 같은 파일을 동시에 수정하지 않도록 작업 영역을 미리 나눕니다 (SPEC §8 역할·파일 소유권).

```bash
git switch main && git pull
git switch -c feat/작업이름
# 작업 후
git add <파일> && git commit -m "변경 요약"
git push -u origin feat/작업이름
# GitHub에서 main 대상 PR 생성
```

AI 코딩 에이전트를 사용할 때는 [AGENTS.md](AGENTS.md)를 함께 읽게 합니다.

## 비밀정보

API 키, 서비스 계정 JSON, `google-services.json`, 서명 키(keystore) 등은 커밋하지 않습니다.
환경변수 이름과 설명은 [.env.example](.env.example)에만 기록하고, 실제 값은 각자 로컬 `.env`에 둡니다.
