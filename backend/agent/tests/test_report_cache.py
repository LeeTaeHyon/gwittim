from datetime import date, datetime, timedelta, timezone

from backend.agent.report_cache import (
    KST, cache_key, is_expired, ledger_expires_at, report_expires_at,
)

PAYLOAD = {"chips": ["web_ui", "any"], "interests": ["ai", "data"], "stage": "none"}


def test_same_input_same_key():
    assert cache_key("n1", PAYLOAD) == cache_key("n1", dict(PAYLOAD))
    assert len(cache_key("n1", PAYLOAD)) == 64


def test_changed_chip_changes_key():
    other = {**PAYLOAD, "chips": ["web_ui", "backend"]}
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
