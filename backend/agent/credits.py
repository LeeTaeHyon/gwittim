"""크레딧 계산 순수 함수 (docs/agent-privacy-spec.md §10.3, D-039).

저장소 접근 없음. 상태는 불변이고, 모든 함수는 새 상태를 돌려준다.
시각을 받는 함수는 시간대 없는 datetime을 KST로 본다.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import date, datetime, time, timedelta, timezone
from typing import Literal

KST = timezone(timedelta(hours=9), "KST")

MAX_CREDITS = 5
SIGNUP_GIFT = 5
DAILY_CHARGE = 1

SIGNUP = "signup"
DAILY = "daily"
DETAIL_ANALYSIS = "detail_analysis"
EXTERNAL_SEARCH = "external_search"

# 차감 종류별 비용
COSTS = {DETAIL_ANALYSIS: 1, EXTERNAL_SEARCH: 2}

# charged 차감함 / duplicate 이미 처리한 요청 / failed 분석 실패 / insufficient 잔액 부족
DeductStatus = Literal["charged", "duplicate", "failed", "insufficient"]


@dataclass(frozen=True)
class LedgerEntry:
    kind: str
    amount: int
    at: datetime
    ref: str | None = None  # 공고 id 또는 요청 id


@dataclass(frozen=True)
class CreditState:
    balance: int
    last_charge_date: date  # KST 날짜
    processed_request_ids: frozenset[str] = frozenset()
    entries: tuple[LedgerEntry, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class DeductResult:
    state: CreditState
    status: DeductStatus


def to_kst(moment: datetime) -> datetime:
    """시간대 없는 datetime은 KST로 간주한다."""
    if moment.tzinfo is None:
        return moment.replace(tzinfo=KST)
    return moment.astimezone(KST)


def signup(now: datetime) -> CreditState:
    now = to_kst(now)
    return CreditState(
        balance=SIGNUP_GIFT,
        last_charge_date=now.date(),
        entries=(LedgerEntry(SIGNUP, SIGNUP_GIFT, now),),
    )


def apply_refill(state: CreditState, now: datetime) -> CreditState:
    """마지막 충전 날짜 다음 날부터 오늘까지 하루 +1(최대 5). 시계가 거꾸로 가면 그대로."""
    today = to_kst(now).date()
    if today <= state.last_charge_date:
        return state
    balance = state.balance
    entries = list(state.entries)
    day = state.last_charge_date
    while day < today:
        day += timedelta(days=1)
        if balance >= MAX_CREDITS:
            continue  # 가득 차 못 채운 날은 내역 없음
        balance += DAILY_CHARGE
        entries.append(LedgerEntry(DAILY, DAILY_CHARGE, datetime.combine(day, time(0), tzinfo=KST)))
    return replace(state, balance=balance, last_charge_date=today, entries=tuple(entries))


def deduct(
    state: CreditState,
    kind: str,
    request_id: str,
    succeeded: bool,
    now: datetime,
    ref: str | None = None,
) -> DeductResult:
    """성공한 요청에만 차감한다. 같은 request_id는 한 번만. 충전 반영을 먼저 한다."""
    if kind not in COSTS:
        raise ValueError(f"알 수 없는 차감 종류: {kind}")
    state = apply_refill(state, now)
    if request_id in state.processed_request_ids:
        return DeductResult(state, "duplicate")
    if not succeeded:
        # 실패는 처리한 요청으로 기록하지 않는다(같은 id로 재시도해 성공하면 차감).
        return DeductResult(state, "failed")
    cost = COSTS[kind]
    if state.balance < cost:
        return DeductResult(state, "insufficient")
    entry = LedgerEntry(kind, -cost, to_kst(now), ref if ref is not None else request_id)
    return DeductResult(
        replace(
            state,
            balance=state.balance - cost,
            processed_request_ids=state.processed_request_ids | {request_id},
            entries=state.entries + (entry,),
        ),
        "charged",
    )


def next_refill_at(state: CreditState, now: datetime) -> datetime | None:
    """다음 충전 시각(다음 날 0시 KST). 최대 보유면 None."""
    state = apply_refill(state, now)
    if state.balance >= MAX_CREDITS:
        return None
    today = max(to_kst(now).date(), state.last_charge_date)
    return datetime.combine(today + timedelta(days=1), time(0), tzinfo=KST)
