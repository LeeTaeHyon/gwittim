"""지원 조건 비교 (SPEC §6 지원 조건)."""
from __future__ import annotations


def _compare(condition: dict, profile_value) -> bool:
    if condition["operator"] == "eq":
        return profile_value == condition["value"]
    return profile_value in condition["value"]


def evaluate(eligibility: dict, profile: dict) -> tuple[str, list[dict]]:
    """Notice.eligibility와 UserProfile로 (eligibility_status, condition_results)를 만든다.

    - 검증된 필수 조건 중 하나라도 확실히 불충족 → not_met
    - 불충족 없이 미입력·미해석 조건, 불완전한 추출, 조건 못 찾음이 있으면 → needs_check
    - 전체 조건 해석이 확인되고 모두 충족 → met
    - 명시적 제한 없음(explicitly_unrestricted) → met
    """
    if eligibility["explicitly_unrestricted"]:
        return "met", []

    results = []
    for cond in eligibility["conditions"]:
        field = cond["field"]
        if cond["validation_status"] != "validated":
            results.append(_result(field, "unknown", cond["evidence"], "condition_unresolved"))
        elif profile.get(field) is None:
            results.append(_result(field, "unknown", cond["evidence"], "profile_missing"))
        else:
            status = "met" if _compare(cond, profile[field]) else "not_met"
            results.append(_result(field, status, cond["evidence"], None))

    statuses = {r["status"] for r in results}
    if "not_met" in statuses:
        return "not_met", results
    incomplete = (
        "unknown" in statuses
        or not eligibility["conditions"]
        or eligibility["unresolved_conditions"]
        or not eligibility["extraction_complete"]
    )
    return ("needs_check" if incomplete else "met"), results


def _result(field: str, status: str, evidence: str | None, unknown_reason: str | None) -> dict:
    return {"field": field, "status": status, "evidence": evidence, "unknown_reason": unknown_reason}
