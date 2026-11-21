"""크레딧 계산 순수 함수 (docs/agent-privacy-spec.md §10.3, D-039).

저장소 접근 없음. 상태는 불변이고, 모든 함수는 새 상태를 돌려준다.
시각을 받는 함수는 시간대 없는 datetime을 KST로 본다.

차감은 두 단계다. AI를 부르기 전에 reserve로 잡아 두고(held일 때만 AI 호출),
결과가 나오면 settle로 확정(성공)하거나 돌려준다(실패).
여러 요청이 동시에 오는 경우는 저장소 트랜잭션에서 상태 읽기~reserve~쓰기를 한 번에 해야 막힌다(P7).
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

# 잡아 둔 크레딧이 이 시간 안에 확정·환불되지 않으면 다음 잡아 두기 때 돌려준다.
# LLM 호출 제한 시간(120초)보다 넉넉하게 둔다.
HOLD_TIMEOUT = timedelta(minutes=10)

# 사용 내역·처리한 요청 id 보관 기간 (명세 §4 크레딧 내역 90일). 90일째가 되는 시각에 지운다.
HISTORY_RETENTION = timedelta(days=90)

# held 잡아 둠(AI 호출 가능) / duplicate 이미 확정한 요청 / in_progress 같은 요청이 진행 중
# / insufficient 잔액 부족. held가 아니면 AI를 부르지 않는다.
ReserveStatus = Literal["held", "duplicate", "in_progress", "insufficient"]
# charged 차감 확정 / refunded 실패라 돌려줌 / no_hold 잡아 둔 것이 없음(이미 확정·환불·만료)
SettleStatus = Literal["charged", "refunded", "no_hold"]


@dataclass(frozen=True)
class LedgerEntry:
    kind: str
    amount: int
    at: datetime
    ref: str | None = None  # 공고 id 또는 요청 id


@dataclass(frozen=True)
class Hold:
    request_id: str
    kind: str
    cost: int
    at: datetime


@dataclass(frozen=True)
class CreditState:
    balance: int  # 지금 쓸 수 있는 크레딧(잡아 둔 것은 이미 빠짐)
    last_charge_date: date  # KST 날짜
    processed: tuple[tuple[str, datetime], ...] = ()  # (요청 id, 확정 시각)
    entries: tuple[LedgerEntry, ...] = field(default_factory=tuple)
    holds: tuple[Hold, ...] = ()

    @property
    def processed_request_ids(self) -> frozenset[str]:
        return frozenset(rid for rid, _ in self.processed)

    @property
    def held(self) -> int:
        return sum(h.cost for h in self.holds)


@dataclass(frozen=True)
class ReserveResult:
    state: CreditState
    status: ReserveStatus


@dataclass(frozen=True)
class SettleResult:
    state: CreditState
    status: SettleStatus


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
    """마지막 충전 날짜 다음 날부터 오늘까지 하루 +1(최대 5). 시계가 거꾸로 가면 그대로.

    최대 보유는 지금 쓸 수 있는 잔액(balance)만으로 센다. 잡아 둔 크레딧은 세지 않으므로
    자정을 넘긴 요청이 성공해도 그날 충전이 빠지지 않는다. 환불 때 5를 넘으면 5로 자른다.
    """
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


def release_stale_holds(state: CreditState, now: datetime) -> CreditState:
    """HOLD_TIMEOUT이 지난 잡아 두기를 환불한다 (서버가 중간에 멈춘 경우)."""
    now = to_kst(now)
    stale = [h for h in state.holds if now - h.at >= HOLD_TIMEOUT]
    if not stale:
        return state
    return replace(
        state,
        balance=min(state.balance + sum(h.cost for h in stale), MAX_CREDITS),
        holds=tuple(h for h in state.holds if h not in stale),
    )


def prune_history(state: CreditState, now: datetime) -> CreditState:
    """HISTORY_RETENTION(90일)이 지난 내역과 처리한 요청 id를 지운다.

    지운 요청 id로 다시 요청하면 새 요청으로 본다(90일 뒤 재시도는 다시 차감).
    """
    now = to_kst(now)
    entries = tuple(e for e in state.entries if now - e.at < HISTORY_RETENTION)
    processed = tuple(p for p in state.processed if now - p[1] < HISTORY_RETENTION)
    if len(entries) == len(state.entries) and len(processed) == len(state.processed):
        return state
    return replace(state, entries=entries, processed=processed)


def current_state(state: CreditState, now: datetime) -> CreditState:
    """읽거나 쓸 때 쓰는 지금 상태: 충전 반영 → 10분 지난 잡아 두기 환불 → 90일 지난 내역 정리.

    크레딧 페이지 조회, next_refill_at, reserve, settle 모두 이것을 거친다(명세 §10.3 '읽거나 쓸 때 계산').
    """
    return prune_history(release_stale_holds(apply_refill(state, now), now), now)


def reserve(state: CreditState, kind: str, request_id: str, now: datetime) -> ReserveResult:
    """1단계: AI를 부르기 전에 크레딧을 잡아 둔다. held일 때만 AI를 부른다.

    순서: 충전 반영 → 오래된 잡아 두기 환불 → 이미 확정한 요청 → 진행 중인 요청 → 잔액.
    held가 아니면 상태(충전 반영 제외)는 바뀌지 않는다.
    """
    if kind not in COSTS:
        raise ValueError(f"알 수 없는 차감 종류: {kind}")
    state = current_state(state, now)
    if request_id in state.processed_request_ids:
        return ReserveResult(state, "duplicate")
    if any(h.request_id == request_id for h in state.holds):
        return ReserveResult(state, "in_progress")
    cost = COSTS[kind]
    if state.balance < cost:
        return ReserveResult(state, "insufficient")
    hold = Hold(request_id, kind, cost, to_kst(now))
    return ReserveResult(replace(state, balance=state.balance - cost, holds=state.holds + (hold,)), "held")


def settle(
    state: CreditState,
    request_id: str,
    succeeded: bool,
    now: datetime,
    ref: str | None = None,
) -> SettleResult:
    """2단계: AI 결과에 따라 확정하거나 돌려준다.

    - 성공: 차감 확정, 내역에 남기고 요청 id를 '처리함'으로 기록(같은 id 재요청은 duplicate).
    - 실패: 잡아 둔 크레딧을 돌려준다(최대 5). 내역·'처리함' 기록 없음(같은 id로 다시 잡아 둘 수 있다).
    - 잡아 둔 것이 없으면 no_hold(이미 확정·환불했거나 10분이 지나 자동 환불됨). 이 결과는 사용자에게 주지 않는다.
    - 먼저 current_state로 충전·만료 환불·오래된 내역 정리를 반영한다.
    """
    state = current_state(state, now)
    hold = next((h for h in state.holds if h.request_id == request_id), None)
    if hold is None:
        return SettleResult(state, "no_hold")
    holds = tuple(h for h in state.holds if h is not hold)
    if not succeeded:
        refunded = min(state.balance + hold.cost, MAX_CREDITS)
        return SettleResult(replace(state, balance=refunded, holds=holds), "refunded")
    entry = LedgerEntry(hold.kind, -hold.cost, to_kst(now), ref if ref is not None else request_id)
    return SettleResult(
        replace(
            state,
            holds=holds,
            processed=state.processed + ((request_id, to_kst(now)),),
            entries=state.entries + (entry,),
        ),
        "charged",
    )


def next_refill_at(state: CreditState, now: datetime) -> datetime | None:
    """다음 충전 시각(다음 날 0시 KST). 최대 보유면 None."""
    state = current_state(state, now)
    if state.balance >= MAX_CREDITS:
        return None
    today = max(to_kst(now).date(), state.last_charge_date)
    return datetime.combine(today + timedelta(days=1), time(0), tzinfo=KST)
