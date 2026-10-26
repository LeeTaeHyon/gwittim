"""추천 목록 생성 (SPEC §6 추천, §7 list_recommendations). 서버 실행 환경과 무관한 순수 함수."""
from __future__ import annotations

from datetime import date

from .config import (
    EXCLUDED_CATEGORIES,
    EXCLUDED_LIFECYCLE,
    EXCLUDED_PUBLICATION,
    MAX_LIMIT,
    RANKING_VERSION,
    STALE_UNKNOWN_DAYS,
)
from .eligibility import evaluate
from .scoring import factors, score

_SUMMARY_FIELDS = (
    "notice_id",
    "notice_version",
    "title",
    "category",
    "source_url",
    "published",
    "application_deadline",
    "deadline_note",
    "lifecycle_status",
)

_FACTOR_REASONS = {"interest": "interest_match", "role": "role_match", "major": "major_match"}


def is_stale(notice: dict, today: date) -> bool:
    """마감일을 모르는 채로 게시 후 STALE_UNKNOWN_DAYS일이 지난 공고. 게시일 미상이면 판단하지 않는다."""
    published = notice["published"]
    if notice["lifecycle_status"] != "unknown" or published is None:
        return False
    return (today - date.fromisoformat(published["date"])).days > STALE_UNKNOWN_DAYS


def has_personal_input(profile: dict) -> bool:
    return bool(profile.get("interest_ids") or profile.get("target_role_ids") or profile.get("major_id"))


def recommend(notices: list[dict], profile: dict, *, today: date, generated_at: str, limit: int = 20) -> dict:
    """list_recommendations 응답을 만든다.

    - review_pending, closed, removed, not_met, 행정 공지(admin_notice), 오래된 마감 미상 공고는 기본 추천에서 제외
    - 프로필에 관심사·직무·전공이 없으면 mode=latest: 점수 없이 게시일 내림차순
    - 정렬: 점수 내림차순(점수 없음은 뒤) → 게시일 내림차순(미상은 뒤) → notice_id
    - 초기에는 소량 결과를 한 번에 돌려준다 (next_cursor=None, SPEC §7)
    """
    limit = max(1, min(limit, MAX_LIMIT))
    mode = "personalized" if has_personal_input(profile) else "latest"

    items = []
    for notice in notices:
        if (
            notice["lifecycle_status"] in EXCLUDED_LIFECYCLE
            or notice["publication_status"] in EXCLUDED_PUBLICATION
            or notice["category"] in EXCLUDED_CATEGORIES
            or is_stale(notice, today)
        ):
            continue
        status, condition_results = evaluate(notice["eligibility"], profile)
        if status == "not_met":
            continue

        reason_codes = []
        item_score = None
        if mode == "personalized":
            values = factors(notice, profile, today)
            item_score = score(values)
            if item_score is not None:
                reason_codes += [code for name, code in _FACTOR_REASONS.items() if values[name] == 1.0]
                if values["timing"] == 1.0:
                    reason_codes.append("deadline_timing")
        reason_codes.append("eligibility_met" if status == "met" else "eligibility_needs_check")

        items.append(
            {
                "recommendation": {
                    "notice_id": notice["notice_id"],
                    "notice_version": notice["notice_version"],
                    "score": item_score,
                    "eligibility_status": status,
                    "condition_results": condition_results,
                    "reason_codes": reason_codes,
                    "generated_at": generated_at,
                    "ranking_version": RANKING_VERSION,
                },
                "notice": {k: notice[k] for k in _SUMMARY_FIELDS},
            }
        )

    items.sort(key=_sort_key)
    return {"mode": mode, "items": items[:limit], "next_cursor": None, "generated_at": generated_at}


def _sort_key(item: dict):
    s = item["recommendation"]["score"]
    published = item["notice"]["published"]
    ordinal = date.fromisoformat(published["date"]).toordinal() if published else 0
    return (s is None, -(s or 0), published is None, -ordinal, item["notice"]["notice_id"])
