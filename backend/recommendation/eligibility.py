"""지원 조건 비교 (SPEC §6 지원 조건)."""
from __future__ import annotations

# unresolved_condition.note에 정해 두고 쓰는 값 (backend.analysis.rules의 PREFERRED_NOTE·NO_LIMIT_NOTE와 같은 값, 테스트로 묶음).
# 둘 다 지원 자격이 아니라서 판정·확인 필요에 넣지 않는다 (D-056).
PREFERRED_NOTE = "우대 사항"
NO_LIMIT_NOTE = "항목 제한 없음"
FLAG_NOTES = (PREFERRED_NOTE, NO_LIMIT_NOTE)


def _compare(condition: dict, profile_value) -> bool:
    if condition["operator"] == "eq":
        return profile_value == condition["value"]
    return profile_value in condition["value"]


def evaluate(eligibility: dict, profile: dict) -> tuple[str, list[dict]]:
    """Notice.eligibility와 UserProfile로 (eligibility_status, condition_results)를 만든다.

    - 검증된 필수 조건 중 하나라도 확실히 불충족 → not_met
    - 불충족 없이 미입력·미해석 조건, 불완전한 추출, 조건 못 찾음이 있으면 → needs_check
    - 전체 조건 해석이 확인되고 모두 충족 → met
    - 명시적 제한 없음(explicitly_unrestricted)이고 추출이 완전하며 미해석 조건이 없을 때만 바로 met.
      제한 없음 문구가 있어도 미해석 조건·불완전한 추출이 있으면 아래 일반 판정으로 needs_check가 된다
    - 프로필 값이 조건의 value에 있으면 충족, unconfirmed_values에 있으면 확인 필요(value_unconfirmed), 프로필이 비었으면
      profile_missing이 먼저, 그 밖이면 미충족. unconfirmed_values가 없는 옛 데이터는 빈 배열로 보아 결과가 같다 (D-057)
    - 우대 사항과 항목 제한 없음 표시가 붙은 미해석 항목은 미해석 조건으로 세지 않는다 (D-056)
    """
    unresolved = [u for u in eligibility["unresolved_conditions"] if u.get("note") not in FLAG_NOTES]
    if eligibility["explicitly_unrestricted"] and eligibility["extraction_complete"] and not unresolved:
        return "met", []

    results = []
    for cond in eligibility["conditions"]:
        field = cond["field"]
        if cond["validation_status"] != "validated":
            results.append(_result(field, "unknown", cond["evidence"], "condition_unresolved"))
        elif profile.get(field) is None:
            results.append(_result(field, "unknown", cond["evidence"], "profile_missing"))
        else:
            if _compare(cond, profile[field]):
                results.append(_result(field, "met", cond["evidence"], None))
            elif profile[field] in (cond.get("unconfirmed_values") or []):
                # 공고가 그 값을 포함하는지 말하지 않았다: 맞다고도 아니라고도 정하지 않는다 (D-057)
                results.append(_result(field, "unknown", cond["evidence"], "value_unconfirmed"))
            else:
                results.append(_result(field, "not_met", cond["evidence"], None))

    statuses = {r["status"] for r in results}
    if "not_met" in statuses:
        return "not_met", results
    incomplete = (
        "unknown" in statuses
        or not eligibility["conditions"]
        or unresolved
        or not eligibility["extraction_complete"]
    )
    return ("needs_check" if incomplete else "met"), results


def _result(field: str, status: str, evidence: str | None, unknown_reason: str | None) -> dict:
    return {"field": field, "status": status, "evidence": evidence, "unknown_reason": unknown_reason}
