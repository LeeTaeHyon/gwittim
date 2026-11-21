from datetime import date, datetime, timedelta, timezone

from backend.agent.report_cache import (
    KST, cache_key, deadline_from_date_info, is_expired, ledger_expires_at, report_expires_at,
)

# 보낼 값 생성기(#105 build_payload) 결과와 같은 키
PAYLOAD = {
    "university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 2,
    "enrollment_status": "enrolled", "interest_ids": ["ai_data", "software"],
    "target_role_ids": ["software_developer"], "experience": ["web_ui", "python"],
    "period": "vacation", "regions": ["seoul"],
}


def test_same_input_same_key():
    assert cache_key("n1", PAYLOAD) == cache_key("n1", dict(PAYLOAD))
    assert len(cache_key("n1", PAYLOAD)) == 64


def test_changed_chip_changes_key():
    other = {**PAYLOAD, "experience": ["web_ui", "app_dev"]}
    assert cache_key("n1", PAYLOAD) != cache_key("n1", other)


def test_different_notice_changes_key():
    assert cache_key("n1", PAYLOAD) != cache_key("n2", PAYLOAD)


def test_dict_key_order_ignored():
    a = {"a": 1, "b": {"x": 1, "y": 2}}
    b = {"b": {"y": 2, "x": 1}, "a": 1}
    assert cache_key("n1", a) == cache_key("n1", b)


def test_list_order_ignored():
    a = {"chips": ["a", "b", "c"], "n": {"k": ["x", "y"]}}
    b = {"chips": ["c", "a", "b"], "n": {"k": ["y", "x"]}}
    assert cache_key("n1", a) == cache_key("n1", b)


def test_korean_values_stable():
    assert cache_key("n1", {"m": ["컴퓨터"]}) == cache_key("n1", {"m": ["컴퓨터"]})


def test_deadline_plus_30_days_from_start_of_day_kst():
    exp = report_expires_at(date(2026, 11, 19), datetime(2026, 11, 1, tzinfo=KST))
    assert exp == datetime(2026, 12, 19, 0, 0, tzinfo=KST)


def test_deadline_none_plus_60_days():
    created = datetime(2026, 11, 19, 10, 0, tzinfo=KST)
    assert report_expires_at(None, created) == created + timedelta(days=60)
    assert report_expires_at(None, created) == datetime(2027, 1, 18, 10, 0, tzinfo=KST)


def test_month_and_year_boundaries():
    created = datetime(2026, 1, 1, tzinfo=KST)
    assert report_expires_at(date(2026, 1, 31), created) == datetime(2026, 3, 2, tzinfo=KST)
    assert report_expires_at(date(2026, 12, 31), created) == datetime(2027, 1, 30, tzinfo=KST)
    assert report_expires_at(date(2028, 2, 10), created) == datetime(2028, 3, 11, tzinfo=KST)  # 윤년


def test_deadline_datetime_used_as_is():
    dl = datetime(2026, 11, 19, 18, 0, tzinfo=KST)
    assert report_expires_at(dl, dl) == datetime(2026, 12, 19, 18, 0, tzinfo=KST)


def test_naive_treated_as_kst():
    naive = datetime(2026, 11, 19, 9, 0)
    assert report_expires_at(None, naive) == datetime(2027, 1, 18, 9, 0, tzinfo=KST)


def test_is_expired_boundary():
    exp = datetime(2026, 12, 20, tzinfo=KST)
    assert not is_expired(exp, exp - timedelta(seconds=1))
    assert is_expired(exp, exp)
    assert is_expired(exp, exp + timedelta(days=1))
    utc_now = (exp - timedelta(hours=1)).astimezone(timezone.utc)
    assert not is_expired(exp, utc_now)


def test_ledger_90_days():
    created = datetime(2026, 11, 19, 12, 0, tzinfo=KST)
    assert ledger_expires_at(created) == datetime(2027, 2, 17, 12, 0, tzinfo=KST)
    assert ledger_expires_at(datetime(2026, 12, 31, tzinfo=KST)) == datetime(2027, 3, 31, tzinfo=KST)


def test_each_chip_change_changes_key():
    base = cache_key("n1", PAYLOAD)
    assert cache_key("n1", {**PAYLOAD, "period": "semester"}) != base
    assert cache_key("n1", {**PAYLOAD, "regions": ["seoul", "gyeonggi_incheon"]}) != base
    assert cache_key("n1", {k: v for k, v in PAYLOAD.items() if k != "experience"}) != base


def info(day, clock=None, zone=None, precision="date"):
    return {"date": day, "time": clock, "timezone": zone, "precision": precision, "evidence": "합성"}


def test_date_info_date_precision_uses_start_of_day():
    created = datetime(2026, 11, 1, tzinfo=KST)
    assert report_expires_at(info("2026-11-19"), created) == datetime(2026, 12, 19, 0, 0, tzinfo=KST)


def test_date_info_minute_kst():
    created = datetime(2026, 11, 1, tzinfo=KST)
    got = report_expires_at(info("2026-11-19", "18:00", "Asia/Seoul", "minute"), created)
    assert got == datetime(2026, 12, 19, 18, 0, tzinfo=KST)


def test_date_info_minute_utc():
    assert deadline_from_date_info(info("2026-11-19", "09:00", "UTC", "minute")) == datetime(
        2026, 11, 19, 9, 0, tzinfo=timezone.utc
    )


def test_date_info_minute_without_timezone_uses_date_only():
    # 시간대 미상이면 시각을 KST로 단정하지 않는다(AGENTS §1)
    created = datetime(2026, 11, 1, tzinfo=KST)
    got = report_expires_at(info("2026-11-19", "18:00", None, "minute"), created)
    assert got == datetime(2026, 12, 19, 0, 0, tzinfo=KST)


def test_date_info_none_is_unknown_deadline():
    created = datetime(2026, 11, 19, 10, 0, tzinfo=KST)
    assert deadline_from_date_info(None) is None
    assert report_expires_at(None, created) == created + timedelta(days=60)
