import copy
import json
from datetime import date
from pathlib import Path

import pytest

from backend.contracts import schema_errors
from backend.recommendation import evaluate, factors, recommend, score, timing_factor
from backend.recommendation.major_prior import load_prior, major_prior_factor

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
    [("2026-10-17", 1.0), ("2026-10-31", 1.0), ("2026-11-01", 0.6), ("2026-11-16", 0.6), ("2026-11-17", 0.3), ("2026-10-16", 0.0)],
)
def test_timing_bands(notices, deadline, expected):
    n = copy.deepcopy(notices[0])
    n["application_deadline"]["date"] = deadline
    assert timing_factor(n, TODAY) == expected


def test_no_deadline_scores_zero(notices):
    assert timing_factor(notices[1], TODAY) == 0.0  # 선착순, deadline_note만 있음


def test_dated_notice_ranks_above_same_undated_notice(notices, profile):
    """관심도가 같으면 마감이 멀어도(시기 0.3) 마감일 없는 공고보다 앞선다 (D-024)."""
    far = copy.deepcopy(notices[3])
    far["notice_id"], far["application_deadline"]["date"] = "n_far", "2026-12-31"
    undated = copy.deepcopy(notices[3])
    undated["notice_id"], undated["application_deadline"], undated["lifecycle_status"] = "n_undated", None, "unknown"
    undated["published"] = {**undated["published"], "date": "2026-10-16"}  # 더 최근 게시여도
    out = recommend([undated, far], profile, today=TODAY, generated_at=NOW)
    assert [i["recommendation"]["notice_id"] for i in out["items"]] == ["n_far", "n_undated"]


def test_unevaluable_factors_leave_denominator(notices, profile):
    values = factors(notices[3], profile, TODAY)
    # 컴공 학생에게 소프트웨어 공고는 학과 통계에서도 1위 분야
    assert values == {"interest": 1.0, "role": 1.0, "major": 1.0, "major_prior": 1.0, "timing": 1.0}
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
    assert top["reason_codes"] == ["interest_match", "role_match", "major_match", "major_prior_match", "deadline_timing", "eligibility_met"]
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


def test_old_notice_without_deadline_excluded(notices, profile):
    old = copy.deepcopy(notices[1])  # 0002: 확정 마감일 없음
    old.update(lifecycle_status="unknown")
    old["published"]["date"] = "2026-08-17"  # TODAY 61일 전
    recent = copy.deepcopy(old)
    recent.update(notice_id="n_recent")
    recent["published"]["date"] = "2026-08-18"  # 60일 전까지는 남긴다
    dated = copy.deepcopy(notices[0])  # 마감일을 아는 공고는 게시일과 무관
    dated["published"]["date"] = "2026-01-02"
    for p in (profile, {}):
        ids = [i["notice"]["notice_id"] for i in recommend([old, recent, dated], p, today=TODAY, generated_at=NOW)["items"]]
        assert ids.count("n_synthetic_0002") == 0 and "n_recent" in ids and "n_synthetic_0001" in ids


# ---------- 학과 통계 (D-020) ----------

def major_only(major_id: str) -> dict:
    return dict(fixture("user_profile/empty.json"), university_id="mjc", major_id=major_id)


def test_major_prior_value(notices, profile):
    business = major_only("mjc.business_administration")
    # 0001: business_marketing (경영학과 관심사 1위) → 1.0
    assert major_prior_factor(notices[0], business) == 1.0
    # 0003: culture_arts는 경영학과에서 거의 안 가는 분야 → 0에 가까움
    assert major_prior_factor(notices[2], business) < 0.01
    # 관심사·직무를 골라도 같은 값으로 평가한다
    assert major_prior_factor(notices[0], dict(business, interest_ids=["software"], target_role_ids=["marketer"])) == 1.0
    # 통계표에 없는 학과(자유전공), 학과 미입력
    assert major_prior_factor(notices[0], major_only("mjc.undeclared")) is None
    assert major_prior_factor(notices[0], fixture("user_profile/empty.json")) is None


def test_chosen_interest_outranks_major_stats(notices):
    # 경영학과 학생이 culture_arts를 고르면, 학과 통계 1위 분야 공고(0001)보다 고른 분야 공고(0003)가 앞선다
    student = dict(major_only("mjc.business_administration"), interest_ids=["culture_arts"])
    out = recommend(notices, student, today=TODAY, generated_at=NOW)
    ids = [i["notice"]["notice_id"] for i in out["items"]]
    assert ids.index("n_synthetic_0003") < ids.index("n_synthetic_0001")
    first = next(i for i in out["items"] if i["notice"]["notice_id"] == "n_synthetic_0001")["recommendation"]
    assert "major_prior_match" in first["reason_codes"] and "interest_match" not in first["reason_codes"]


def test_major_only_profile_ranks_by_major_stats(notices):
    out = recommend(notices, major_only("mjc.business_administration"), today=TODAY, generated_at=NOW)
    assert schema_errors("recommendation_list_response", out) == []
    assert out["mode"] == "personalized"
    top = out["items"][0]["recommendation"]
    assert out["items"][0]["notice"]["notice_id"] == "n_synthetic_0001"
    assert "major_prior_match" in top["reason_codes"]
    # 통계 값이 낮은 공고에는 이유를 붙이지 않는다
    culture = next(i for i in out["items"] if i["notice"]["notice_id"] == "n_synthetic_0003")
    assert "major_prior_match" not in culture["recommendation"]["reason_codes"]
    assert culture["recommendation"]["score"] is not None  # 0점으로 평가됨 (학과 꼬리표가 없어도)


def test_major_prior_table_covers_dictionary():
    majors = json.loads((ROOT / "contracts/dictionaries/majors.json").read_text(encoding="utf-8"))["items"]
    table = load_prior()
    missing = sorted(m["id"] for m in majors if m["id"] not in table)
    assert missing == ["mjc.undeclared"]  # 자유전공학과는 대응하는 커리어넷 학과가 없다
