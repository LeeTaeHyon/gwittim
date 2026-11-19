from datetime import datetime, timedelta, timezone

from backend.agent.credits import (
    DAILY,
    DETAIL_ANALYSIS,
    EXTERNAL_SEARCH,
    KST,
    SIGNUP,
    apply_refill,
    deduct,
    next_refill_at,
    signup,
)

T0 = datetime(2026, 11, 1, 10, 0, tzinfo=KST)


def spend(state, kind, rid, now, ok=True):
    return deduct(state, kind, rid, ok, now)


def drained_to(balance):
    """가입 직후 상태에서 잔액을 balance(4, 1, 0 중 하나)로 만든다."""
    plans = {
        4: [(DETAIL_ANALYSIS, "a")],
        1: [(EXTERNAL_SEARCH, "a"), (EXTERNAL_SEARCH, "b")],
        0: [(EXTERNAL_SEARCH, "a"), (EXTERNAL_SEARCH, "b"), (DETAIL_ANALYSIS, "c")],
    }
    s = signup(T0)
    for kind, rid in plans[balance]:
        s = spend(s, kind, rid, T0).state
    assert s.balance == balance
    return s


def test_signup_gives_five():
    s = signup(T0)
    assert s.balance == 5
    assert s.last_charge_date == T0.date()
    assert [(e.kind, e.amount) for e in s.entries] == [(SIGNUP, 5)]


def test_naive_datetime_is_kst_and_utc_converted():
    assert signup(datetime(2026, 11, 1, 10, 0)).entries[0].at == T0
    # UTC 11-01 16:00 = KST 11-02 01:00
    assert signup(datetime(2026, 11, 1, 16, 0, tzinfo=timezone.utc)).last_charge_date.day == 2


def test_next_day_adds_one():
    s = drained_to(4)
    s = apply_refill(s, T0 + timedelta(days=1))
    assert s.balance == 5
    assert s.entries[-1].kind == DAILY
    assert s.entries[-1].at == datetime(2026, 11, 2, 0, 0, tzinfo=KST)


def test_full_balance_stays_five_without_entries():
    s = signup(T0)
    r = apply_refill(s, T0 + timedelta(days=3))
    assert r.balance == 5
    assert len(r.entries) == 1
    assert r.last_charge_date == (T0 + timedelta(days=3)).date()


def test_many_days_fill_at_once_and_stop_at_five():
    s = drained_to(1)
    n_before = len(s.entries)
    r = apply_refill(s, T0 + timedelta(days=10))
    assert r.balance == 5
    assert len(r.entries) - n_before == 4
    assert all(e.kind == DAILY for e in r.entries[n_before:])


def test_same_request_id_not_charged_twice():
    r1 = spend(signup(T0), DETAIL_ANALYSIS, "r1", T0)
    r2 = spend(r1.state, DETAIL_ANALYSIS, "r1", T0)
    assert (r1.status, r2.status) == ("charged", "duplicate")
    assert r2.state.balance == 4
    assert len(r2.state.entries) == 2


def test_failed_analysis_not_charged_and_retry_can_charge():
    r = spend(signup(T0), DETAIL_ANALYSIS, "r1", T0, ok=False)
    assert r.status == "failed" and r.state.balance == 5
    assert len(r.state.entries) == 1
    r2 = spend(r.state, DETAIL_ANALYSIS, "r1", T0)
    assert r2.status == "charged" and r2.state.balance == 4


def test_insufficient_does_not_charge_or_record():
    s = drained_to(0)
    r = spend(s, DETAIL_ANALYSIS, "z", T0)
    assert r.status == "insufficient" and r.state.balance == 0
    assert "z" not in r.state.processed_request_ids
    # 잔액 1에서 외부 공고 찾기(2)도 부족
    assert spend(drained_to(1), EXTERNAL_SEARCH, "e", T0).status == "insufficient"


def test_deduct_applies_refill_first():
    s = drained_to(0)
    r = spend(s, DETAIL_ANALYSIS, "z", T0 + timedelta(days=1))
    assert r.status == "charged" and r.state.balance == 0
    assert [e.kind for e in r.state.entries[-2:]] == [DAILY, DETAIL_ANALYSIS]


def test_kst_midnight_boundary():
    s = drained_to(4)
    assert apply_refill(s, datetime(2026, 11, 1, 23, 59, tzinfo=KST)).balance == 4
    assert apply_refill(s, datetime(2026, 11, 2, 0, 0, tzinfo=KST)).balance == 5
    # UTC 15:00 = KST 다음 날 0시
    assert apply_refill(s, datetime(2026, 11, 1, 15, 0, tzinfo=timezone.utc)).balance == 5
    assert apply_refill(s, datetime(2026, 11, 1, 14, 59, tzinfo=timezone.utc)).balance == 4


def test_clock_going_backwards_does_nothing():
    s = drained_to(4)
    assert apply_refill(s, T0 - timedelta(days=2)) is s


def test_next_refill_at():
    s = drained_to(4)
    assert next_refill_at(s, T0) == datetime(2026, 11, 2, 0, 0, tzinfo=KST)
    assert next_refill_at(signup(T0), T0) is None
    assert next_refill_at(s, T0 + timedelta(days=1)) is None  # 채워져 최대 보유


def test_state_is_immutable():
    s = signup(T0)
    spend(s, DETAIL_ANALYSIS, "r1", T0)
    assert s.balance == 5 and not s.processed_request_ids
