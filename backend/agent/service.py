"""AI 상세 분석·크레딧 흐름 (SPEC §7, docs/agent-privacy-spec.md §4·§5·§10).

FastAPI와 분리한 순수 흐름이다. 실패는 AgentError(code)로 알리고, 앱 계층이 오류 응답으로 바꾼다.
저장소·시계·제공자는 deps(backend.api.deps.Deps)에서 받는다.

차감 순서: 크레딧 잡아 두기(reserve, 트랜잭션) → LLM 호출(트랜잭션 밖) → 확정 또는 환불(settle, 트랜잭션).
프롬프트·리포트 원문·uid는 로그에 남기지 않는다.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import TYPE_CHECKING

from backend.contracts import schema_errors
from backend.recommendation import evaluate

from .credits import DETAIL_ANALYSIS, current_state, next_refill_at, reserve, settle, signup
from .llm import generate_report
from .payload import build_payload
from .prompt import build_messages
from .report_cache import cache_key, is_expired, report_expires_at

if TYPE_CHECKING:
    from backend.api.deps import Deps, ReportStore

log = logging.getLogger("gwittim.agent.service")


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


def request_analysis(uid: str, body: dict, deps: Deps) -> dict:
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
    key = cache_key(notice_id, payload)
    stored = _live(deps.reports.get_by_key(uid, key), now)

    def do_reserve(state):
        result = reserve(state or signup(now), DETAIL_ANALYSIS, request_id, now)
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
            result = settle(state or signup(now), request_id, succeeded, now, ref=notice_id)
            return result.state, result.status

        return deps.credits.update(uid, fn)

    if stored is not None:  # 같은 입력은 저장본을 주고 차감한다 (D-039). LLM은 부르지 않는다
        finish(True)
        return _response(stored, True)

    try:
        system, user = build_messages(
            notice, payload, evaluate(notice["eligibility"], profile), deps.today_kst(),
        )
        result = generate_report(system, user, provider=deps.llm, notice_id=notice_id)
        doc = {
            "notice_id": notice_id,
            "key": key,
            "report": result.report,
            "created_at": now,
            "expires_at": report_expires_at(notice["application_deadline"], now),
            "request_id": request_id,
        }
        deps.reports.put(uid, doc)
    except Exception as exc:  # LLM 실패·저장 실패 모두 환불. 원문은 로그에 남기지 않는다
        log.warning("analysis failed notice_id=%s error=%s", notice_id, type(exc).__name__)
        finish(False)
        raise AgentError("unavailable") from None
    finish(True)
    return _response(doc, False)


def get_analysis(uid: str, notice_id: str, deps: Deps) -> dict:
    doc = deps.reports.latest_for_notice(uid, notice_id, deps.clock.now())
    if doc is None:
        raise AgentError("not_found")
    return _response(doc, True)


def get_credits(uid: str, deps: Deps) -> dict:
    now = deps.clock.now()

    def fn(state):
        current = current_state(state or signup(now), now)
        refill = next_refill_at(current, now)
        view = {
            "balance": current.balance,
            "next_refill_at": utc_z(refill) if refill else None,
            # 같은 시각이면 나중에 쌓인 것이 먼저 오도록 뒤집고 정렬한다
            "entries": [
                {"kind": e.kind, "amount": e.amount, "at": utc_z(e.at), "ref": e.ref}
                for e in sorted(reversed(current.entries), key=lambda e: e.at, reverse=True)
            ],
        }
        return current, view

    return deps.credits.update(uid, fn)


def purge_expired_reports(reports: ReportStore, now: datetime) -> int:
    """만료된 저장본을 모든 사용자에 걸쳐 지운다(명세 §4 하루 배치). 지운 개수를 돌려준다."""
    return reports.delete_expired(now)
