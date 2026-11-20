"""에이전트(LLM)로 보낼 값 생성기. 근거: docs/agent-privacy-spec.md §2, P1.

허용 목록 방식이다. 아래 두 묶음 밖의 키는 어떤 경로로도 결과에 들어가지 않는다.
- 기본(§2.1): university_id, major_id, grade, enrollment_status, interest_ids, target_role_ids
- 요청 때 칩(§2.2): experience(해 본 것), period(가능한 시기), regions(갈 수 있는 지역)

사전 밖 값, 모르는 키, None, 잘못된 타입은 오류 없이 버린다.
값이 없는 칸은 키를 결과에서 뺀다(미상으로 두고 추정하지 않는다).
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from backend.dictionaries import codes

# 칩 허용 목록(명세 §2.2). 영어 snake_case 코드 -> 한국어 이름.
# 공통 사전(contracts/dictionaries) 반영은 별도 승인 작업이라 여기에 상수로 둔다.
EXPERIENCE_CHIPS: dict[str, str] = {
    "python": "파이썬",
    "java": "자바",
    "web_ui": "웹 화면",
    "app_dev": "앱 개발",
    "data_analysis": "데이터 분석",
    "design_tool": "디자인 도구",
    "video_editing": "영상 편집",
    "team_project": "팀 프로젝트",
    "contest": "공모전 참가",
    "outside_activity": "대외활동",
    "internship": "현장실습·인턴",
    "none_yet": "아직 없음",
}
EXPERIENCE_NONE = "none_yet"  # 단독 선택. 다른 칩과 함께 오면 서로 어긋나므로 experience를 통째로 버린다.
PERIOD_CHIPS: dict[str, str] = {
    "semester": "학기 중",
    "vacation": "방학",
    "any": "상관없음",
}
REGION_CHIPS: dict[str, str] = {
    "seoul": "서울",
    "gyeonggi_incheon": "경기·인천",
    "online_only": "온라인만",
    "any": "상관없음",
}

ENROLLMENT_STATUSES = frozenset({"enrolled", "on_leave", "graduated"})
MAX_SELECTIONS = 5  # SPEC §5: 관심사·직무 각 최대 5개

ALLOWED_KEYS = frozenset(
    {
        "university_id", "major_id", "grade", "enrollment_status", "interest_ids", "target_role_ids",
        "experience", "period", "regions",
    }
)


def _code_list(value: Any, allowed, limit: int | None = None) -> list[str]:
    """문자열 또는 문자열 목록에서 허용 값만, 순서 유지·중복 제거로 뽑는다."""
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, (list, tuple, set, frozenset)):
        return []
    out: list[str] = []
    for item in value:
        if isinstance(item, str) and item in allowed and item not in out:
            out.append(item)
    return out[:limit] if limit else out


def _single(value: Any, allowed) -> str | None:
    """하나만 허용. 문자열이거나 유효값 정확히 1개짜리 목록이면 채택, 여러 개면 버린다."""
    values = _code_list(value, allowed)
    return values[0] if len(values) == 1 and (isinstance(value, str) or len(value) == 1) else None


def build_payload(profile: Mapping | None, chips: Mapping | None = None) -> dict:
    """프로필과 칩에서 허용 필드만 담은 dict를 만든다.

    칩 처리 규칙:
    - experience, regions: 여러 개. 사전 안 값만 순서 유지·중복 제거로 담는다.
    - experience의 none_yet(아직 없음)은 단독 선택. 다른 칩과 함께 오면 어느 쪽이 맞는지
      알 수 없으므로 experience를 통째로 버린다(앱은 화면에서 미리 막는다).
    - period: 하나만. 유효값이 정확히 하나일 때만 담고, 여러 개(유효하지 않은 값이 섞여
      원소 수가 달라도 포함)가 오면 고르지 않고 통째로 버린다(보수적 규칙, 추정 없음).
    - 유효값이 없으면 키를 뺀다.
    """
    profile = profile if isinstance(profile, Mapping) else {}
    chips = chips if isinstance(chips, Mapping) else {}
    result: dict[str, Any] = {}

    university = profile.get("university_id")
    if isinstance(university, str) and university in codes("universities"):
        result["university_id"] = university
    major = profile.get("major_id")
    if isinstance(major, str) and major in codes("majors"):
        result["major_id"] = major
    grade = profile.get("grade")
    if isinstance(grade, int) and not isinstance(grade, bool) and 1 <= grade <= 4:
        result["grade"] = grade
    status = profile.get("enrollment_status")
    if isinstance(status, str) and status in ENROLLMENT_STATUSES:
        result["enrollment_status"] = status
    interests = _code_list(profile.get("interest_ids"), codes("interests"), MAX_SELECTIONS)
    if interests:
        result["interest_ids"] = interests
    roles = _code_list(profile.get("target_role_ids"), codes("roles"), MAX_SELECTIONS)
    if roles:
        result["target_role_ids"] = roles

    experience = _code_list(chips.get("experience"), EXPERIENCE_CHIPS)
    if EXPERIENCE_NONE in experience and len(experience) > 1:
        experience = []
    if experience:
        result["experience"] = experience
    raw_period = chips.get("period")
    if isinstance(raw_period, (list, tuple, set, frozenset)) and len(raw_period) != 1:
        period = None
    else:
        period = _single(raw_period, PERIOD_CHIPS)
    if period:
        result["period"] = period
    regions = _code_list(chips.get("regions"), REGION_CHIPS)
    if regions:
        result["regions"] = regions
    return result
