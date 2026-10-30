"""관심도 점수 (SPEC §6 추천 4~6, D-005 #8).

평가 불가 요소는 분모에서 뺀다. 개인화 요소(관심사·직무·전공)를 하나도 평가할 수 없으면 점수를 만들지 않는다.
"""
from __future__ import annotations

from datetime import date

from .config import PERSONAL_FACTORS, TIMING_BANDS, WEIGHTS
from .major_prior import major_prior_factor


def _overlap(profile_codes, notice_codes) -> float | None:
    if not profile_codes or not notice_codes:
        return None
    return 1.0 if set(profile_codes) & set(notice_codes) else 0.0


def timing_factor(notice: dict, today: date) -> float | None:
    """마감까지 남은 날짜(날짜 단위 비교). 마감일이 없거나 지났으면 평가 불가.

    today는 호출자가 Asia/Seoul 기준 날짜로 넘긴다. 시각·시간대가 미상이어도 날짜만으로 평가한다.
    """
    deadline = notice["application_deadline"]
    if deadline is None:
        return None
    days = (date.fromisoformat(deadline["date"]) - today).days
    if days < 0:
        return None
    for upper, value in TIMING_BANDS:
        if upper is None or days <= upper:
            return value
    return None


def factors(notice: dict, profile: dict, today: date) -> dict[str, float | None]:
    major = None
    if profile.get("major_id") and notice["related_majors"]:
        major = 1.0 if profile["major_id"] in notice["related_majors"] else 0.0
    return {
        "interest": _overlap(profile.get("interest_ids"), notice["interest_tags"]),
        "role": _overlap(profile.get("target_role_ids"), notice["related_roles"]),
        "major": major,
        "major_prior": major_prior_factor(notice, profile),
        "timing": timing_factor(notice, today),
    }


def score(factor_values: dict[str, float | None]) -> float | None:
    """100 × 가중합 / 평가 가능한 가중치 합. 개인화 요소가 모두 평가 불가면 None."""
    if all(factor_values.get(name) is None for name in PERSONAL_FACTORS):
        return None
    evaluable = {name: v for name, v in factor_values.items() if v is not None}
    total_weight = sum(WEIGHTS[name] for name in evaluable)
    return round(100 * sum(WEIGHTS[name] * v for name, v in evaluable.items()) / total_weight, 2)
