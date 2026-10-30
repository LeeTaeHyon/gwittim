"""학과 통계 보조 점수 (D-017, 목표 2 방식 A).

contracts/stats/major_prior.json: 학과별 졸업생 진로 통계로 계산한 P(직무|학과)·P(관심사|학과).
- 관심사·직무를 하나도 고르지 않은 학생에게만 평가한다. 직접 고른 학생의 점수는 바뀌지 않는다.
- 값 = 공고 꼬리표 중 가장 잘 맞는 하나의 학과 확률 ÷ 그 학과의 가장 큰 확률. 직무·관심사 중 큰 쪽.
  합이 아니라 최댓값: 꼬리표를 많이 단 공고가 유리해지지 않게 한다.
- 프로필에는 아무것도 쓰지 않는다. 학생 정보를 추정해 확정하지 않는다 (AGENTS.md).
"""
from __future__ import annotations

import json
from functools import cache
from pathlib import Path

PRIOR_PATH = Path(__file__).resolve().parents[2] / "contracts/stats/major_prior.json"


@cache
def load_prior() -> dict[str, dict]:
    return json.loads(PRIOR_PATH.read_text(encoding="utf-8"))["majors"]


def _share(dist: dict[str, float], codes: list[str]) -> float | None:
    if not dist or not codes:
        return None
    return max(dist.get(c, 0.0) for c in codes) / max(dist.values())


def major_prior_factor(notice: dict, profile: dict) -> float | None:
    if profile.get("interest_ids") or profile.get("target_role_ids"):
        return None
    dist = load_prior().get(profile.get("major_id") or "")
    if dist is None:
        return None
    values = [
        v
        for v in (_share(dist["roles"], notice["related_roles"]), _share(dist["interests"], notice["interest_tags"]))
        if v is not None
    ]
    return round(max(values), 4) if values else None
