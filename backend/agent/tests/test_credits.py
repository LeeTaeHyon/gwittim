from datetime import datetime, timedelta, timezone

from backend.agent.credits import (
    DAILY,
    DETAIL_ANALYSIS,
    EXTERNAL_SEARCH,
    KST,
    SIGNUP,
    HOLD_TIMEOUT,
    apply_refill,
    next_refill_at,
    reserve,
    settle,
    signup,
)

T0 = datetime(2026, 11, 1, 10, 0, tzinfo=KST)


def spend(state, kind, rid, now, ok=True):
    """잡아 두고 바로 확정(또는 환불)한다. 잡아 두지 못하면 그 결과를 돌려준다."""
    r = reserve(state, kind, rid, now)
    if r.status != "held":
        return r
    return settle(r.state, rid, ok, now)


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


def test_reserve_holds_then_settle_charges():
    r = reserve(signup(T0), DETAIL_ANALYSIS, "r1", T0)
    assert r.status == "held"
    assert r.state.balance == 4 and r.state.held == 1
    assert len(r.state.entries) == 1  # 잡아 두기만으로는 내역 없음
    c = settle(r.state, "r1", True, T0, ref="notice-9")
    assert c.status == "charged"
    assert c.state.balance == 4 and c.state.held == 0
    assert "r1" in c.state.processed_request_ids
    assert (c.state.entries[-1].kind, c.state.entries[-1].amount, c.state.entries[-1].ref) == (
        DETAIL_ANALYSIS, -1, "notice-9",
    )


def test_same_request_id_not_charged_twice():
    r1 = spend(signup(T0), DETAIL_ANALYSIS, "r1", T0)
    r2 = reserve(r1.state, DETAIL_ANALYSIS, "r1", T0)
    assert (r1.status, r2.status) == ("charged", "duplicate")
    assert r2.state.balance == 4 and r2.state.held == 0  # AI를 다시 부르지 않음
    assert len(r2.state.entries) == 2


def test_same_request_in_progress_is_not_held_twice():
    r1 = reserve(signup(T0), DETAIL_ANALYSIS, "r1", T0)
    r2 = reserve(r1.state, DETAIL_ANALYSIS, "r1", T0)
    assert r2.status == "in_progress"
    assert r2.state.balance == 4 and r2.state.held == 1


def test_double_tap_at_balance_one_holds_only_one():
    s = drained_to(1)
    r1 = reserve(s, DETAIL_ANALYSIS, "a1", T0)
    r2 = reserve(r1.state, DETAIL_ANALYSIS, "a2", T0)  # 다른 요청 id로 연타
    assert (r1.status, r2.status) == ("held", "insufficient")
    assert r2.state.balance == 0 and r2.state.held == 1


def test_failure_refunds_without_entry_and_retry_can_charge():
    r = reserve(signup(T0), DETAIL_ANALYSIS, "r1", T0)
    f = settle(r.state, "r1", False, T0)
    assert f.status == "refunded"
    assert f.state.balance == 5 and f.state.held == 0
    assert len(f.state.entries) == 1
    assert "r1" not in f.state.processed_request_ids
    r2 = spend(f.state, DETAIL_ANALYSIS, "r1", T0)
    assert r2.status == "charged" and r2.state.balance == 4


def test_external_search_refund_returns_two():
    r = reserve(signup(T0), EXTERNAL_SEARCH, "e1", T0)
    assert r.state.balance == 3
    assert settle(r.state, "e1", False, T0).state.balance == 5


def test_settle_without_hold_changes_nothing():
    s = signup(T0)
    none = settle(s, "nope", True, T0)
    assert none.status == "no_hold" and none.state is s
    c = spend(s, DETAIL_ANALYSIS, "r1", T0)
    again = settle(c.state, "r1", True, T0)  # 두 번 확정
    assert again.status == "no_hold" and again.state is c.state
    refunded = spend(s, DETAIL_ANALYSIS, "r2", T0, ok=False)
    assert settle(refunded.state, "r2", False, T0).status == "no_hold"  # 두 번 환불 안 됨


def test_stale_hold_is_refunded_on_next_reserve():
    r = reserve(signup(T0), EXTERNAL_SEARCH, "e1", T0)
    early = reserve(r.state, DETAIL_ANALYSIS, "x", T0 + HOLD_TIMEOUT - timedelta(seconds=1))
    assert early.state.held == 3  # e1(2) + x(1)
    late = reserve(r.state, DETAIL_ANALYSIS, "x", T0 + HOLD_TIMEOUT)
    assert late.status == "held"
    assert late.state.balance == 4 and late.state.held == 1  # e1 환불 후 x만 잡힘
    assert settle(late.state, "e1", True, T0 + HOLD_TIMEOUT).status == "no_hold"


def test_refill_counts_holds_so_refund_never_exceeds_five():
    r = reserve(signup(T0), DETAIL_ANALYSIS, "r1", T0)  # 4 + 잡아 둠 1
    next_day = T0 + timedelta(hours=20)
    s = apply_refill(r.state, next_day)
    assert s.balance == 4  # 4 + 1(잡아 둠) = 5라 충전 없음
    assert next_refill_at(r.state, T0) is None
    assert settle(s, "r1", False, next_day).state.balance == 5


def test_insufficient_does_not_hold_or_record():
    s = drained_to(0)
    r = reserve(s, DETAIL_ANALYSIS, "z", T0)
    assert r.status == "insufficient" and r.state.balance == 0
    assert r.state.held == 0  # AI를 부르지 않음
    assert "z" not in r.state.processed_request_ids
    # 다음 날 충전 뒤 같은 id로 다시 잡아 둘 수 있다
    assert spend(r.state, DETAIL_ANALYSIS, "z", T0 + timedelta(days=1)).status == "charged"
    # 잔액 1에서 외부 공고 찾기(2)도 부족
    assert spend(drained_to(1), EXTERNAL_SEARCH, "e", T0).status == "insufficient"


def test_reserve_applies_refill_first():
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
    r = reserve(s, DETAIL_ANALYSIS, "r1", T0)
    settle(r.state, "r1", True, T0)
    assert s.balance == 5 and not s.processed_request_ids and not s.holds
    assert r.state.balance == 4 and not r.state.processed_request_ids
