# contracts — 공통 계약

SPEC §5·§7의 필드 의미를 JSON Schema(Draft 2020-12)로 고정합니다. 결정 근거는 [D-005](../docs/decisions.md)입니다. 변경은 AGENTS.md §3 절차를 따르며 SPEC·스키마·`fixtures/`·소비 코드를 같은 PR에서 갱신합니다.

| 파일 | 대상 |
|---|---|
| `common.schema.json` | 날짜 객체, 조건, eligibility, 첨부, 공고 요약 등 공통 정의 |
| `raw_notice.schema.json` | 수집기 출력 |
| `notice.schema.json` | 앱이 사용하는 공고 |
| `user_profile.schema.json` | 사용자 프로필 |
| `recommendation_item.schema.json` | 추천 항목 |
| `recommendation_list_response.schema.json` | `list_recommendations` 응답 (`mode`) |
| `saved_notice.schema.json`, `saved_notice_list_response.schema.json` | 저장, 저장 목록 응답 |
| `api_error.schema.json` | API 오류 응답 |
| `dictionary.schema.json`, `dictionaries/*.json` | 공통 사전 (모두 `draft`) |

## 검증

```bash
uv sync
uv run python tools/validate_contracts.py
```

- 스키마 검증 외에 의미 검증 두 가지를 함께 실행합니다: 사전 코드 존재 여부, `eligibility_status`와 조건 판정의 일치(SPEC §6).
- 스키마 통과는 날짜 해석·원문 근거·지원 조건 해석이 맞다는 뜻이 아닙니다.
- `format: uri`는 jsonschema 기본 설치에서 검사되지 않습니다(추가 패키지 필요). 현재 URI 형식은 검증하지 않습니다.
- `content_hash`는 형식만 검사합니다. 실제 계산 규칙의 일치는 수집기 구현에서 검증합니다.
