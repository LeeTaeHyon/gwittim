"""AI 상세 분석·크레딧 흐름 (SPEC §7, docs/agent-privacy-spec.md §4·§5·§10).

FastAPI와 분리한 순수 흐름이다. 실패는 AgentError(code)로 알리고, 앱 계층이 오류 응답으로 바꾼다.
저장소·시계·제공자는 deps(backend.api.deps.Deps)에서 받는다.

차감 순서: 크레딧 잡아 두기(reserve, 트랜잭션) → LLM 호출(트랜잭션 밖) → 확정 또는 환불(settle, 트랜잭션).
프롬프트·리포트 원문·uid는 로그에 남기지 않는다.
"""
from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from typing import TYPE_CHECKING

from backend.contracts import schema_errors
from backend.recommendation import evaluate

from .credits import DETAIL_ANALYSIS, current_state, demo_refill, next_refill_at, reserve, settle, signup
from .llm import generate_report
from .payload import build_payload
from .prompt import HARNESS_VERSION, build_messages, ground_report, scrub_codes, split_long_lines
from .report_cache import cache_key, is_expired, report_expires_at

if TYPE_CHECKING:
    from backend.api.deps import Deps, ReportStore

log = logging.getLogger("gwittim.agent.service")

CAP_ENV = "GWITTIM_LLM_MONTHLY_CAP_KRW"
DEFAULT_CAP_KRW = 30000.0  # D-039


def monthly_cap_krw() -> float:
    try:
        cap = float(os.environ.get(CAP_ENV, ""))
    except ValueError:
        return DEFAULT_CAP_KRW
    return cap if cap >= 0 else DEFAULT_CAP_KRW


def _add_spend(deps: Deps, month: str, krw: float | None) -> None:
    """비용을 모르면(None) 0. 누적 실패가 사용자 응답을 막지 않게 한다."""
    if not krw or krw <= 0:
        return
    try:
        deps.spend.add(month, krw)
    except Exception as exc:
        log.warning("spend add failed error=%s", type(exc).__name__)


class AgentError(Exception):
    """code는 api_error 계약의 오류 코드."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def utc_z(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _response(doc: dict, from_cache: bool) -> dict:
    return {
        "notice_id": doc["notice_id"],
        "report": doc["report"],
        "expires_at": utc_z(doc["expires_at"]),
        "from_cache": from_cache,
    }


def _live(doc: dict | None, now: datetime) -> dict | None:
    return doc if doc is not None and not is_expired(doc["expires_at"], now) else None


def request_analysis(uid: str, body: dict, deps: Deps, guest: bool = False) -> dict:
    if not isinstance(body, dict) or schema_errors("analysis_request", body):
        raise AgentError("invalid_argument")
    profile = deps.profiles.get(uid)
    if profile is None or not profile.get("agent_consent"):
        raise AgentError("consent_required")
    notice_id, request_id = body["notice_id"], body["request_id"]
    notice = deps.notices.get(notice_id)
    if notice is None:
        raise AgentError("not_found")

    now = deps.clock.now()
    payload = build_payload(profile, body["chips"])
    key = cache_key(notice_id, payload, HARNESS_VERSION)
    stored = _live(deps.reports.get_by_key(uid, key), now)

    month = deps.month_kst()
    # 월 상한: 새 LLM 호출이 필요할 때만 막는다. 저장본 재사용은 상한과 무관. 크레딧을 잡기 전에 본다
    if stored is None and deps.spend.get(month) >= monthly_cap_krw():
        raise AgentError("unavailable")

    def do_reserve(state):
        result = reserve(state or signup(now, guest), DETAIL_ANALYSIS, request_id, now, guest)
        return result.state, result.status

    status = deps.credits.update(uid, do_reserve)
    if status == "insufficient":
        raise AgentError("insufficient_credits")
    if status == "in_progress":
        raise AgentError("request_in_progress")
    if status == "duplicate":  # 같은 요청 id는 이미 차감됨. 차감 없이 그 저장본을 준다
        if stored is None:
            raise AgentError("not_found")
        return _response(stored, True)

    def finish(succeeded: bool):
        def fn(state):
            result = settle(state or signup(now, guest), request_id, succeeded, now, ref=notice_id, guest=guest)
            return result.state, result.status

        return deps.credits.update(uid, fn)

    if stored is not None:  # 같은 입력은 저장본을 주고 차감한다 (D-039). LLM은 부르지 않는다
        finish(True)
        return _response(stored, True)

    spent = False
    try:
        verdict = evaluate(notice["eligibility"], profile)
        system, user = build_messages(notice, payload, verdict, deps.today_kst())
        result = generate_report(system, user, provider=deps.llm, notice_id=notice_id)
        _add_spend(deps, month, result.usage.cost_krw)
        spent = True
        report, scrubbed = scrub_codes(result.report)  # 지시문을 어기고 새어 나온 내부 코드를 한국어로
        report, split = split_long_lines(report)  # 한 문단으로 온 칸은 문장 끝에서 줄로 나눔(화면은 줄 = 항목)
        # 역량은 원문 근거가 있는 줄만, 마감 지남·미충족 할 일은 판단을 바꿀 행동만
        report, grounded = ground_report(report, notice, verdict[0], deps.today_kst())
        if grounded:
            log.info("report grounded notice_id=%s %s", notice_id,
                     " ".join(f"{k}={v}" for k, v in sorted(grounded.items())))
        if split:
            log.info("report lines split notice_id=%s count=%d", notice_id, split)
        if scrubbed:
            log.info("report codes scrubbed notice_id=%s count=%d", notice_id, scrubbed)
        doc = {
            "notice_id": notice_id,
            "key": key,
            "harness_version": HARNESS_VERSION,  # 어느 지침으로 만든 리포트인지 (원문은 남기지 않음)
            "report": report,
            "created_at": now,
            "expires_at": report_expires_at(notice["application_deadline"], now),
            "request_id": request_id,
        }
        deps.reports.put(uid, doc)
        log.info("analysis created notice_id=%s harness=%s provider=%s cost_krw=%s",
                 notice_id, HARNESS_VERSION, result.usage.provider, result.usage.cost_krw)
    except Exception as exc:  # LLM 실패·저장 실패 모두 환불. 원문은 로그에 남기지 않는다
        log.warning("analysis failed notice_id=%s harness=%s error=%s", notice_id, HARNESS_VERSION, type(exc).__name__)
        usage = getattr(exc, "usage", None)  # 실패한 호출도 토큰이 있으면 비용이 든 것으로 센다
        if not spent and usage is not None:
            _add_spend(deps, month, usage.cost_krw)
        finish(False)
        raise AgentError("unavailable") from None
    finish(True)
    return _response(doc, False)


def get_analysis(uid: str, notice_id: str, deps: Deps) -> dict:
    doc = deps.reports.latest_for_notice(uid, notice_id, deps.clock.now())
    if doc is None:
        raise AgentError("not_found")
    return _response(doc, True)


def _credit_view(current, now: datetime, guest: bool = False) -> dict:
    refill = next_refill_at(current, now, guest)
    return {
        "balance": current.balance,
        "next_refill_at": utc_z(refill) if refill else None,
        # 같은 시각이면 나중에 쌓인 것이 먼저 오도록 뒤집고 정렬한다
        "entries": [
            {"kind": e.kind, "amount": e.amount, "at": utc_z(e.at), "ref": e.ref}
            for e in sorted(reversed(current.entries), key=lambda e: e.at, reverse=True)
        ],
    }


def get_credits(uid: str, deps: Deps, guest: bool = False) -> dict:
    now = deps.clock.now()

    def fn(state):
        current = current_state(state or signup(now, guest), now, guest)
        return current, _credit_view(current, now, guest)

    return deps.credits.update(uid, fn)


DEMO_ENV = "GWITTIM_DEMO_CREDITS"


def demo_credits_enabled() -> bool:
    """시연 기간에만 서버 설정 GWITTIM_DEMO_CREDITS=1로 켠다. 꺼져 있으면 채우기 경로가 없는 것처럼 404.
    켜 두어도 월 비용 상한(GWITTIM_LLM_MONTHLY_CAP_KRW)은 그대로 막는다."""
    return os.environ.get(DEMO_ENV, "").strip() == "1"


def demo_refill_credits(uid: str, deps: Deps, guest: bool = False) -> dict:
    """시연용: 잔액을 5까지 채우고 크레딧 페이지와 같은 모양으로 돌려준다."""
    now = deps.clock.now()

    def fn(state):
        current = demo_refill(state or signup(now, guest), now, guest)
        return current, _credit_view(current, now, guest)

    return deps.credits.update(uid, fn)


def purge_expired_reports(reports: ReportStore, now: datetime) -> int:
    """만료된 저장본을 모든 사용자에 걸쳐 지운다(명세 §4 하루 배치). 지운 개수를 돌려준다."""
    return reports.delete_expired(now)
