import copy
import json
from datetime import date
from pathlib import Path

import pytest

from backend.contracts import schema_errors
from backend.recommendation import evaluate, factors, recommend, score, timing_factor

ROOT = Path(__file__).resolve().parents[3]
TODAY = date(2026, 10, 17)
NOW = "2026-10-17T03:05:00Z"


def fixture(name: str) -> dict:
    return json.loads((ROOT / "fixtures/valid" / name).read_text(encoding="utf-8"))


@pytest.fixture
def notices():
    names = [
        "date_only_timezone_unknown",  # 0001 contest, grade 2~3, deadline 11-02
        "empty_conditions_incomplete_first_come",  # 0002 global, 조건 못 찾음
        "explicitly_unrestricted",  # 0003
        "minute_precision_changed_deadline",  # 0004 컴공 전용, deadline 10-30
        "closed_review_pending",  # 0005 제외 대상
    ]
    return [fixture(f"notice/{n}.json") for n in names]


@pytest.fixture
def profile():
    return fixture("user_profile/complete.json")  # mjc, 컴공, 2학년, 재학, software·ai_data, software_developer


# ---------- 지원 조건 ----------

def test_all_conditions_met(notices, profile):
    status, results = evaluate(notices[3]["eligibility"], profile)
    assert status == "met"
    assert {r["status"] for r in results} == {"met"}


def test_validated_not_met_wins_over_unknown(notices, profile):
    elig = copy.deepcopy(notices[3]["eligibility"])
    elig["conditions"][0]["validation_status"] = "needs_review"  # unknown
    other = dict(profile, major_id="mjc.business_administration")  # 전공 불충족
    status, results = evaluate(elig, other)
    assert status == "not_met"
    assert {r["status"] for r in results} == {"unknown", "met", "not_met"}


def test_missing_profile_value_is_needs_check(notices, profile):
    status, results = evaluate(notices[0]["eligibility"], dict(profile, grade=None))
    assert status == "needs_check"
    assert [r["unknown_reason"] for r in results if r["status"] == "unknown"] == ["profile_missing"]


def test_empty_conditions_are_not_unrestricted(notices, profile):
    assert evaluate(notices[1]["eligibility"], profile) == ("needs_check", [])


def test_explicitly_unrestricted_is_met(notices, profile):
    assert evaluate(notices[2]["eligibility"], profile) == ("met", [])


def test_unresolved_condition_keeps_needs_check_even_if_all_met(notices, profile):
    elig = copy.deepcopy(notices[0]["eligibility"])
    elig["unresolved_conditions"].append({"evidence": "직전 학기 평점 3.0 이상", "note": None})
    status, results = evaluate(elig, profile)
    assert status == "needs_check"
    assert {r["status"] for r in results} == {"met"}


# ---------- 점수 ----------

@pytest.mark.parametrize(
    ("deadline", "expected"),
    [("2026-10-17", 1.0), ("2026-10-31", 1.0), ("2026-11-01", 0.6), ("2026-11-16", 0.6), ("2026-11-17", 0.3), ("2026-10-16", None)],
)
def test_timing_bands(notices, deadline, expected):
    n = copy.deepcopy(notices[0])
    n["application_deadline"]["date"] = deadline
    assert timing_factor(n, TODAY) == expected


def test_no_deadline_is_not_evaluable(notices):
    assert timing_factor(notices[1], TODAY) is None  # 선착순, deadline_note만 있음


def test_unevaluable_factors_leave_denominator(notices, profile):
    values = factors(notices[3], profile, TODAY)
    assert values == {"interest": 1.0, "role": 1.0, "major": 1.0, "timing": 1.0}
    assert score(values) == 100.0
    # 관심사·전공 평가 불가, 직무 불일치, 시기 0.6 → 100 × (0 + 10×0.6) / (35 + 10)
    assert score({"interest": None, "role": 0.0, "major": None, "timing": 0.6}) == pytest.approx(13.33)


def test_no_personal_factor_means_no_score():
    assert score({"interest": None, "role": None, "major": None, "timing": 1.0}) is None


# ---------- 목록 ----------

def test_personalized_list(notices, profile):
    out = recommend(notices, profile, today=TODAY, generated_at=NOW)
    assert schema_errors("recommendation_list_response", out) == []
    assert out["mode"] == "personalized"
    ids = [i["notice"]["notice_id"] for i in out["items"]]
    assert "n_synthetic_0005" not in ids  # closed·review_pending 제외
    assert ids[0] == "n_synthetic_0004"  # 관심사·직무·전공·시기 모두 일치
    top = out["items"][0]["recommendation"]
    assert top["reason_codes"] == ["interest_match", "role_match", "major_match", "deadline_timing", "eligibility_met"]
    scores = [i["recommendation"]["score"] for i in out["items"]]
    scored = [s for s in scores if s is not None]
    assert scored == sorted(scored, reverse=True)
    assert scores[len(scored):] == [None] * (len(scores) - len(scored))  # 점수 없음은 뒤


def test_not_met_excluded(notices, profile):
    out = recommend(notices, dict(profile, major_id="mjc.business_administration"), today=TODAY, generated_at=NOW)
    assert "n_synthetic_0004" not in [i["notice"]["notice_id"] for i in out["items"]]


def test_admin_notice_excluded(notices, profile):
    notices[0]["category"] = "admin_notice"  # 교직원 채용 등 학생 대상이 아닌 공지
    for p in (profile, {}):
        ids = [i["notice"]["notice_id"] for i in recommend(notices, p, today=TODAY, generated_at=NOW)["items"]]
        assert "n_synthetic_0001" not in ids


def test_latest_mode_without_personal_input(notices):
    empty = fixture("user_profile/empty.json")
    out = recommend(notices, empty, today=TODAY, generated_at=NOW)
    assert schema_errors("recommendation_list_response", out) == []
    assert out["mode"] == "latest"
    assert all(i["recommendation"]["score"] is None for i in out["items"])
    assert all(set(i["recommendation"]["reason_codes"]) <= {"eligibility_met", "eligibility_needs_check"} for i in out["items"])


def test_tie_break_by_published_then_id(notices):
    empty = fixture("user_profile/empty.json")
    a, b, c = (copy.deepcopy(notices[2]) for _ in range(3))
    a["notice_id"], a["published"]["date"] = "n_b", "2026-10-10"
    b["notice_id"], b["published"]["date"] = "n_a", "2026-10-10"
    c["notice_id"], c["published"] = "n_0", None
    d = copy.deepcopy(notices[2])
    d["notice_id"], d["published"]["date"] = "n_z", "2026-10-12"
    out = recommend([c, a, b, d], empty, today=TODAY, generated_at=NOW)
    assert [i["notice"]["notice_id"] for i in out["items"]] == ["n_z", "n_a", "n_b", "n_0"]


def test_limit_capped(notices, profile):
    out = recommend(notices * 30, profile, today=TODAY, generated_at=NOW, limit=500)
    assert len(out["items"]) == 50


def test_three_profiles_explain_differences(notices, profile):
    """P0 검증용: 프로필 3개의 조건·이유 차이. 순위를 억지로 다르게 만들지 않는다."""
    business = dict(profile, major_id="mjc.business_administration", interest_ids=["startup"], target_role_ids=["entrepreneur"])
    first_year = dict(profile, grade=1)
    outs = {name: recommend(notices, p, today=TODAY, generated_at=NOW) for name, p in
            [("computer", profile), ("business", business), ("first_year", first_year)]}
    for out in outs.values():
        assert schema_errors("recommendation_list_response", out) == []
    ids = {name: [i["notice"]["notice_id"] for i in out["items"]] for name, out in outs.items()}
    assert "n_synthetic_0004" in ids["computer"] and "n_synthetic_0004" not in ids["business"]
    assert "n_synthetic_0001" not in ids["first_year"]  # 2~3학년 대상
    assert outs["business"]["items"][0]["notice"]["notice_id"] == "n_synthetic_0001"  # 창업 관심사·직무


def test_personalized_item_without_personal_factor_has_null_score_last(notices, profile):
    untagged = copy.deepcopy(notices[2])
    untagged.update(notice_id="n_untagged", interest_tags=[], related_roles=[], related_majors=[])
    out = recommend([untagged, notices[3]], profile, today=TODAY, generated_at=NOW)
    assert schema_errors("recommendation_list_response", out) == []
    assert out["mode"] == "personalized"
    last = out["items"][-1]["recommendation"]
    assert last["notice_id"] == "n_untagged" and last["score"] is None
    assert last["reason_codes"] == ["eligibility_met"]
