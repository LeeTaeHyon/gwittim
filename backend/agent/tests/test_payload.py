from backend.agent.payload import ALLOWED_KEYS, build_payload

PROFILE = {
    "university_id": "mjc",
    "major_id": "mjc.computer_engineering",
    "grade": 2,
    "enrollment_status": "enrolled",
    "interest_ids": ["ai_data", "software"],
    "target_role_ids": ["software_developer"],
    "updated_at": "2026-11-19T00:00:00Z",
}


def test_full_profile_and_chips():
    chips = {"experience": ["python", "contest"], "period": "vacation", "regions": ["seoul", "online_only"]}
    out = build_payload(PROFILE, chips)
    assert out["university_id"] == "mjc"
    assert out["grade"] == 2
    assert out["interest_ids"] == ["ai_data", "software"]
    assert out["experience"] == ["python", "contest"]
    assert out["period"] == "vacation"
    assert out["regions"] == ["seoul", "online_only"]


def test_personal_and_unknown_keys_never_leak():
    profile = dict(PROFILE, name="홍길동", email="a@b.c", uid="U123", account_id="acc", student_no="2024", free_text="자기소개", x=1)
    chips = {"name": "홍길동", "email": "a@b.c", "uid": "U123", "memo": "자유 글", "period": "semester"}
    out = build_payload(profile, chips)
    assert set(out) <= ALLOWED_KEYS
    flat = repr(out)
    for secret in ("홍길동", "a@b.c", "U123", "acc", "2024", "자기소개", "자유 글"):
        assert secret not in flat


def test_out_of_dictionary_values_dropped():
    profile = dict(PROFILE, university_id="nope", major_id="x.y", enrollment_status="alien", grade=9,
                   interest_ids=["ai_data", "zzz", 5], target_role_ids=["zzz"])
    chips = {"experience": ["python", "rust", "자유글"], "period": "never", "regions": ["mars", "seoul"]}
    out = build_payload(profile, chips)
    assert "university_id" not in out and "major_id" not in out
    assert "grade" not in out and "enrollment_status" not in out
    assert out["interest_ids"] == ["ai_data"]
    assert "target_role_ids" not in out
    assert out["experience"] == ["python"]
    assert "period" not in out
    assert out["regions"] == ["seoul"]


def test_empty_and_none_inputs():
    assert build_payload({}, {}) == {}
    assert build_payload(None, None) == {}
    assert build_payload({"grade": None, "interest_ids": None, "major_id": None}, {"period": None, "experience": None}) == {}
    assert build_payload("garbage", 3) == {}  # type: ignore[arg-type]


def test_period_multiple_values_discarded():
    assert build_payload({}, {"period": ["semester", "vacation"]}) == {}
    assert build_payload({}, {"period": ["semester", "bogus"]}) == {}
    assert build_payload({}, {"period": ["vacation"]}) == {"period": "vacation"}
    assert build_payload({}, {"period": "any"}) == {"period": "any"}


def test_duplicates_removed_and_limit_five():
    interests = ["ai_data", "ai_data", "software"]
    assert build_payload({"interest_ids": interests})["interest_ids"] == ["ai_data", "software"]


def test_result_keys_subset_of_allowlist():
    out = build_payload(PROFILE, {"experience": ["python"], "period": "any", "regions": ["any"]})
    assert set(out) <= ALLOWED_KEYS
    assert "updated_at" not in out


def test_experience_none_yet_is_exclusive():
    assert build_payload({}, {"experience": ["none_yet"]}) == {"experience": ["none_yet"]}
    assert build_payload({}, {"experience": "none_yet"}) == {"experience": ["none_yet"]}
    # 다른 칩과 함께 오면 어긋난 입력이라 experience를 통째로 버린다
    assert build_payload({}, {"experience": ["python", "none_yet"]}) == {}
    assert build_payload({}, {"experience": ["none_yet", "python"], "period": "any"}) == {"period": "any"}
    # 사전 밖 값과 함께면 버려진 값은 세지 않는다
    assert build_payload({}, {"experience": ["none_yet", "unknown_chip"]}) == {"experience": ["none_yet"]}
    assert build_payload({}, {"experience": ["none_yet", "none_yet"]}) == {"experience": ["none_yet"]}


def test_region_any_is_exclusive():
    assert build_payload({}, {"regions": ["any"]}) == {"regions": ["any"]}
    assert build_payload({}, {"regions": "any"}) == {"regions": ["any"]}
    # 다른 칩과 함께 오면 어긋난 입력이라 regions를 통째로 버린다
    assert build_payload({}, {"regions": ["seoul", "any"]}) == {}
    assert build_payload({}, {"regions": ["any", "online_only"], "experience": ["python"]}) == {"experience": ["python"]}
    # 사전 밖 값과 함께면 버려진 값은 세지 않는다
    assert build_payload({}, {"regions": ["any", "busan"]}) == {"regions": ["any"]}
