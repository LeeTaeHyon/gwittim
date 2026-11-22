"""공통 사전(contracts/dictionaries) 코드 확인."""
from __future__ import annotations

import json
from functools import cache

from backend.contracts import CONTRACTS_DIR

PROFILE_FIELDS = {
    "university_id": "universities",
    "major_id": "majors",
    "interest_ids": "interests",
    "target_role_ids": "roles",
}


@cache
def codes(dictionary: str) -> frozenset[str]:
    data = json.loads((CONTRACTS_DIR / "dictionaries" / f"{dictionary}.json").read_text(encoding="utf-8"))
    return frozenset(item["id"] for item in data["items"])


UNLISTED_UNIVERSITY = "unlisted"  # 지원 학교(학교 팩) 밖의 학교. 학과 사전이 없어 major_id는 null (SPEC §5)


def unlisted_with_major(profile: dict) -> bool:
    return profile.get("university_id") == UNLISTED_UNIVERSITY and profile.get("major_id") is not None


def unknown_profile_codes(profile: dict) -> list[str]:
    bad = []
    for field, dictionary in PROFILE_FIELDS.items():
        value = profile.get(field)
        for code in value if isinstance(value, list) else ([] if value is None else [value]):
            if code not in codes(dictionary):
                bad.append(f"{field}={code}")
    return bad
