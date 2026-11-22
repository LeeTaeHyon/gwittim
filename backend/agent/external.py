"""외부 공고 찾기: DeepSeek 웹 검색으로 학교 밖 기회를 찾고, 검색 출처로 검증한다 (D-047, docs/agent-privacy-spec.md §2.3·§12).

흐름: 요청 검사 → 동의·월 상한 → 크레딧 2개 잡아 두기 → 웹 검색 호출 1번 → 출처 검증 → 확정(결과 있음) 또는 환불(결과 없음·실패).

출처 검증 (2026-11-23 시험 호출: 모델 답 3개 중 주소가 검색 출처와 같은 것은 1개, 1개는 주소를, 1개는 주최를 지어냄)
- 주소가 검색 출처에 있으면 그대로 둔다
- 주소는 없지만 공고 이름이 어떤 출처의 제목·요약에 있으면 그 출처 페이지로 주소를 바꾼다(목록 사이트 등)
- 둘 다 아니면 버리지 않고 verified=false('출처 확인 안 됨')로 모델이 낸 주소 그대로 보인다(2026-11-23 팀장).
  주소가 http(s)가 아니면 열 수 없어 버린다. 확인된 결과를 먼저, 확인 안 된 결과를 뒤에 둔다
- 마감일은 그 출처의 제목·요약에 같은 날짜가 있을 때만 보인다(확인 안 된 결과는 마감을 보이지 않음). 확인된 마감이 오늘보다 앞이면 버린다
- 주최는 보이지 않는다(출처로 확인할 수 없음). 대신 출처 사이트 이름(확인 안 된 결과는 주소의 사이트 이름)을 보인다

개인정보: 학생이 적은 한 줄(최대 50자)은 프롬프트에만 넣고 저장·로그·내역에 남기지 않는다. 결과도 서버에 저장하지 않는다.
"""
from __future__ import annotations

import json
import logging
import re
from datetime import date
from pathlib import Path
from typing import TYPE_CHECKING
from urllib.parse import urlsplit

from backend.contracts import schema_errors

from .credits import EXTERNAL_SEARCH, reserve, settle, signup
from .llm import LLMError, ReportFormatError, extract_json, get_provider
from .payload import PERIOD_CHIPS, REGION_CHIPS, build_payload
from .prompt import _name, _student

if TYPE_CHECKING:
    from backend.api.deps import Deps

log = logging.getLogger("gwittim.agent.external")

HARNESS_DIR = Path(__file__).resolve().parent / "harness"
EXTERNAL_PROMPT = (HARNESS_DIR / "external_search.md").read_text(encoding="utf-8").strip()
EXTERNAL_VERSION = (HARNESS_DIR / "EXTERNAL_VERSION").read_text(encoding="utf-8").strip()
QUERY_MAX = 50  # §2.3. 넘으면 거절(자르지 않음)
MAX_ITEMS = 5
REASON_MAX = 200
_NOT_TEXT = re.compile(r"[^0-9A-Za-z가-힣]")
_ISO = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
_MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
           "November", "December")


def _norm_url(url: str) -> str:
    parts = urlsplit(url.strip())
    return f"{parts.scheme.lower()}://{parts.netloc.lower()}{parts.path.rstrip('/')}" + (f"?{parts.query}" if parts.query else "")


def _norm_text(text: str) -> str:
    return _NOT_TEXT.sub("", text or "").lower()


def _date_forms(day: date) -> list[str]:
    """출처 문장에서 찾을 날짜 표기들."""
    y, m, d = day.year, day.month, day.day
    mon = _MONTHS[m - 1]
    return [
        f"{y}-{m:02}-{d:02}", f"{y}.{m:02}.{d:02}", f"{y}.{m}.{d}", f"{y}. {m}. {d}", f"{y}. {m:02}. {d:02}",
        f"{y}/{m:02}/{d:02}", f"{y}년 {m}월 {d}일", f"{m}월 {d}일", f"{m:02}.{d:02}", f"{m}.{d}(", f"~{m}/{d}", f"~ {m}/{d}", f"~{m:02}/{d:02}",
        f"{mon} {d}, {y}", f"{mon[:3]} {d}, {y}", f"{d} {mon} {y}",
    ]


def _parse_day(value) -> date | None:
    m = _ISO.match(value.strip()) if isinstance(value, str) else None
    if not m:
        return None
    try:
        return date(int(m[1]), int(m[2]), int(m[3]))
    except ValueError:
        return None


def ground_items(text: str, sources: list[dict], today: date) -> tuple[list[dict], dict]:
    """모델 답을 검색 출처로 검증한다. (결과, 집계 {'answered', 'kept', 'relinked', 'unverified', 'dropped_past', 'dropped_bad_url'})."""
    try:
        data = extract_json(text)
    except ReportFormatError:
        data = {}
    raw = data.get("items") if isinstance(data.get("items"), list) else []
    by_url = {}
    for s in sources:
        if isinstance(s.get("url"), str) and s["url"].startswith(("http://", "https://")):
            by_url.setdefault(_norm_url(s["url"]), s)
    stats = {"answered": len(raw), "kept": 0, "relinked": 0, "unverified": 0, "dropped_past": 0, "dropped_bad_url": 0}
    verified, unverified, seen = [], [], set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        title = str(item.get("title") or "").strip()
        url = str(item.get("url") or "").strip()
        if not title:
            continue
        src = by_url.get(_norm_url(url)) if url else None
        if src is None:
            key = _norm_text(title)
            if len(key) >= 4:
                src = next((s for s in by_url.values()
                            if key in _norm_text(f"{s.get('title') or ''} {s.get('snippet') or ''}")), None)
                if src is not None:
                    stats["relinked"] += 1
        reason = " ".join(str(item.get("reason") or "").split())[:REASON_MAX] or "검색 결과에서 찾은 공고입니다."
        if src is None:
            # 출처로 확인 못 함: 버리지 않고 표시를 붙여 모델 주소 그대로. 마감은 확인 못 했으므로 보이지 않는다
            if not url.startswith(("http://", "https://")) or not urlsplit(url).netloc:
                stats["dropped_bad_url"] += 1
                continue
            if _norm_url(url) in seen:
                continue
            seen.add(_norm_url(url))
            unverified.append({"title": title[:120], "url": url, "source_name": urlsplit(url).netloc[:60],
                               "deadline": None, "reason": reason, "verified": False})
            continue
        evidence = f"{src.get('title') or ''} {src.get('snippet') or ''}"
        day = _parse_day(item.get("deadline"))
        if day is not None and not any(f in evidence for f in _date_forms(day)):
            day = None  # 출처로 확인하지 못한 마감은 보이지 않는다
        if day is not None and day < today:
            stats["dropped_past"] += 1
            continue
        link = src["url"]
        if _norm_url(link) in seen:
            continue
        seen.add(_norm_url(link))
        verified.append({
            "title": title[:120],
            "url": link,
            "source_name": (src.get("site_name") or urlsplit(link).netloc or "출처")[:60],
            "deadline": day.isoformat() if day else None,
            "reason": reason,
            "verified": True,
        })
    out = (verified + unverified)[:MAX_ITEMS]
    stats["kept"] = sum(i["verified"] for i in out)
    stats["unverified"] = len(out) - stats["kept"]
    return out, stats


def build_search_messages(profile: dict, body: dict, today: date) -> tuple[str, str]:
    """(system, user). 학생 기본 정보는 상세 분석과 같은 허용 목록(build_payload), 찾을 조건은 요청 값."""
    payload = build_payload(profile, {k: body[k] for k in ("period", "regions") if k in body})
    student = _student(payload)
    want: dict = {}
    if body.get("category"):
        want["공고 분류"] = _name("categories", body["category"])
    interests = [c for c in body.get("interests") or [] if _name("interests", c) != "미상"]
    if interests:
        want["관심 분야"] = [_name("interests", c) for c in interests[:5]]
    if payload.get("period"):
        want["가능한 시기"] = PERIOD_CHIPS[payload["period"]]
    if payload.get("regions"):
        want["갈 수 있는 지역"] = [REGION_CHIPS[c] for c in payload["regions"]]
    query = (body.get("query") or "").strip()
    if query:
        want["학생이 적은 한 줄"] = query
    material = {"오늘": today.isoformat(), "학생": student, "찾을 조건": want}
    if student.get("학교"):
        material["학교 공지"] = f"{student['학교']} 공지는 앱에서 따로 받음"
    return EXTERNAL_PROMPT, json.dumps(material, ensure_ascii=False, indent=1)


def request_external_search(uid: str, body: dict, deps: Deps) -> dict:
    from .service import AgentError, _add_spend, monthly_cap_krw, utc_z  # 순환 import 피함

    if not isinstance(body, dict) or schema_errors("external_search_request", body):
        raise AgentError("invalid_argument")
    if len((body.get("query") or "").strip()) > QUERY_MAX:
        raise AgentError("invalid_argument")
    profile = deps.profiles.get(uid)
    if profile is None or not profile.get("agent_consent"):
        raise AgentError("consent_required")
    month = deps.month_kst()
    if deps.spend.get(month) >= monthly_cap_krw():
        raise AgentError("unavailable")
    now = deps.clock.now()
    request_id = body["request_id"]

    def do_reserve(state):
        result = reserve(state or signup(now), EXTERNAL_SEARCH, request_id, now)
        return result.state, result.status

    status = deps.credits.update(uid, do_reserve)
    if status == "insufficient":
        raise AgentError("insufficient_credits")
    if status == "in_progress":
        raise AgentError("request_in_progress")
    if status == "duplicate":  # 결과를 저장하지 않으므로 다시 줄 것이 없다. 이미 차감된 요청
        raise AgentError("not_found")

    def finish(succeeded: bool):
        def fn(state):
            result = settle(state or signup(now), request_id, succeeded, now, ref="external_search")
            return result.state, result.status

        return deps.credits.update(uid, fn)

    provider = deps.llm or get_provider()
    try:
        if not hasattr(provider, "web_search"):
            raise LLMError("이 제공자는 웹 검색을 하지 않습니다")
        system, user = build_search_messages(profile, body, deps.today_kst())
        result = provider.web_search(system, user)
        _add_spend(deps, month, result.usage.cost_krw)
        items, stats = ground_items(result.text, result.sources, deps.today_kst())
    except Exception as exc:  # 원문·한 줄 입력은 로그에 남기지 않는다
        log.warning("external search failed harness=%s error=%s", EXTERNAL_VERSION, type(exc).__name__)
        usage = getattr(exc, "usage", None)
        if usage is not None:
            _add_spend(deps, month, usage.cost_krw)
        finish(False)
        raise AgentError("unavailable") from None
    charged = bool(items)
    finish(charged)  # 찾은 것이 없으면 환불
    log.info("external search done harness=%s provider=%s sources=%d %s cost_krw=%s charged=%s",
             EXTERNAL_VERSION, result.usage.provider, len(result.sources),
             " ".join(f"{k}={v}" for k, v in stats.items()), result.usage.cost_krw, charged)
    return {"items": items, "charged": charged, "searched_at": utc_z(now)}
