# fixtures — 계약 샘플

**모든 샘플은 합성 자료입니다.** 실제 사용자 정보·개인 연락처를 넣지 않습니다. 공고 제목에는 `[합성 샘플]`을 붙입니다.

- `valid/<스키마>/*.json`: 스키마 검증과 의미 검증을 모두 통과해야 하는 샘플
- `invalid/<스키마>/*.json`: `{"_expect": ..., "data": ...}` 형식. `_expect.keyword`·`_expect.path`의 스키마 오류, 또는 `_expect.semantic`의 의미 규칙으로 거부돼야 합니다.

검증: `uv run python tools/validate_contracts.py` (자세한 내용은 [contracts/README.md](../contracts/README.md))

| 사례 (next-work-spec T5) | 샘플 |
|---|---|
| 날짜만 있음·시간대 미상 | `valid/notice/date_only_timezone_unknown`, `valid/raw_notice/mjc_board_date_only` |
| 조건 빈 배열·불완전 추출·첨부 미처리, 선착순 | `valid/notice/empty_conditions_incomplete_first_come` |
| 명시적 제한 없음 | `valid/notice/explicitly_unrestricted`, `invalid/notice/unrestricted_*` |
| 불충족·미확인 공존 → not_met / 미확인 → needs_check / 전부 충족 → met | `valid/recommendation_list_response/*`, `invalid/recommendation_list_response/met_with_*` |
| 내용 변경·버전 | `valid/notice/minute_precision_changed_deadline` |
| review_pending·closed | `valid/notice/closed_review_pending` |
| 웹 원문 없는 출처 (카카오톡 알림톡, D-016) | `valid/raw_notice/kakao_no_url`, `valid/notice/kakao_no_url`, `invalid/raw_notice/no_url_no_id` |
| 개인화 불가 (latest) | `valid/recommendation_list_response/latest_no_profile` |
| 저장 후 마감 변경 | `valid/saved_notice_list_response/deadline_changed_after_save` |
| 학과만 입력 → 학과 통계 보조 점수(D-017) | `valid/user_profile/major_only`, `valid/recommendation_list_response/major_only` |

실제 동작 검증이 아직 없는 사례: 재수집 중복 방지, 분석 실패·단일 403 처리, 기본 추천 제외 규칙, 평가 불가 요소의 분모 제외와 동점 정렬. 이 사례들은 수집기·파이프라인·추천기 구현 후 소비자 테스트로 확인합니다.
