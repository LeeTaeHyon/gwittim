"""외부 공고 찾기: DeepSeek 웹 검색으로 학교 밖 기회를 찾고, 검색 출처로 검증한다 (D-047, docs/agent-privacy-spec.md §2.3·§12).

흐름: 요청 검사 → 동의·월 상한 → 크레딧 2개 잡아 두기 → 웹 검색 호출 1번 → 출처 검증 → 확정(결과 있음) 또는 환불(결과 없음·실패).

출처 검증 (2026-11-23 시험 호출: 모델 답 3개 중 주소가 검색 출처와 같은 것은 1개, 1개는 주소를, 1개는 주최를 지어냄)
- 주소가 검색 출처에 있으면 그대로 둔다
- 주소는 없지만 공고 이름이 어떤 출처의 제목·요약에 있으면 그 출처 페이지로 주소를 바꾼다(목록 사이트 등)
- 둘 다 아니면 버리지 않고 verified=false('출처 확인 안 됨')로 모델이 낸 주소 그대로 보인다(2026-11-23 팀장).
  주소가 http(s)가 아니면 열 수 없어 버린다. 확인된 결과를 먼저, 확인 안 된 결과를 뒤에 둔다
- 마감일은 그 출처의 제목·요약에 같은 날짜가 있을 때만 보인다(확인 안 된 결과는 마감을 보이지 않음). 확인된 마감이 오늘보다 앞이면 버린다
- 주최는 보이지 않는다(출처로 확인할 수 없음). 대신 출처 사이트 이름(확인 안 된 결과는 주소의 사이트 이름)을 보인다

원문 읽고 자격 판정 (2026-11-23 팀장: "링크 목록만으로는 있으나 마나")
- 검색 뒤 두 번째 호출(read_pages)로 남은 후보의 페이지를 DeepSeek가 직접 열고, 주최·접수 마감·응모 대상·학년·학적·학교 제한을
  페이지 문장 그대로(quote) 뽑는다. 생각 끔 검색 호출은 페이지를 스스로 열지 않아서 나눴다
- 서버는 '실제로 연 주소'(read_urls)인 것만 받는다. 페이지 본문은 돌려받지 못해 인용문 자체는 대조할 수 없다(한계)
- 뽑은 값으로 공고 조건(Notice.eligibility 모양)을 만들고 귀띔 판정 규칙(backend.recommendation.evaluate)으로 충족·확인 필요·미충족을 낸다.
  AI는 읽고 판정은 코드가 한다. 미충족은 결과에서 빼고 개수만 알린다(추천 목록과 같은 규칙)
- 졸업 예정 문구는 재학 상태로 판정하지 않고 확인할 조건으로 둔다(D-046)
- 원문을 열지 못한 결과는 판정 없이(verdict null) 검색 결과로만 보인다. 읽기 호출이 실패해도 검색 결과는 준다

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
from backend.recommendation import evaluate

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
READ_PROMPT = (HARNESS_DIR / "external_read.md").read_text(encoding="utf-8").strip()
STATUSES = ("enrolled", "on_leave", "graduated")
_GRADUATING = re.compile(r"졸업\s*예정")
# 응모 대상이 '대학생'뿐이면 재학·휴학 대학생으로 본다(졸업생은 아님). 학적 칸이 비었을 때만 쓴다
_UNIV_STUDENT = re.compile(r"대학생|대학\(원\)생|대학\s*재학생|대학교\s*재(?:학|·휴학)생|대학원생")
_ANYONE = re.compile(r"누구나|제한\s*없음|자격\s*제한\s*없|무관")
# 참가 형태(팀·공동 작품·인원)는 지원 자격 제한이 아니다. 지침에 적어도 모델이 넣는 경우가 있어(2026-11-23 실호출) 서버가 뺀다
_TEAM_RULE = re.compile(r"팀|공동\s*(?:작품|응모|참여)|\d+\s*(?:인|명)\s*(?:이내|이하|까지|으로|로)|개인\s*(?:또는|및|/)")
QUOTE_MAX = 160
VERDICT_ORDER = {"met": 0, "needs_check": 1}
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


def _quote(entry: dict, key: str) -> str | None:
    part = entry.get(key)
    q = part.get("quote") if isinstance(part, dict) else None
    return " ".join(q.split())[:QUOTE_MAX] if isinstance(q, str) and q.strip() else None


def _value(entry: dict, key: str):
    part = entry.get(key)
    return part.get("value") if isinstance(part, dict) else None


def eligibility_from_page(entry: dict) -> dict:
    """원문에서 뽑은 칸 -> Notice.eligibility 모양. 근거 문장(quote)이 없는 값은 쓰지 않는다."""
    conditions, unresolved = [], []
    target = _quote(entry, "target")
    grades = _value(entry, "grades")
    gq = _quote(entry, "grades")
    if isinstance(grades, list) and gq:
        values = sorted({g for g in grades if isinstance(g, int) and 1 <= g <= 4})
        if values and values != [1, 2, 3, 4]:
            conditions.append({"field": "grade", "operator": "in", "value": values, "evidence": gq, "validation_status": "validated"})
    statuses = _value(entry, "statuses")
    sq = _quote(entry, "statuses")
    if isinstance(statuses, list) and sq:
        values = [v for v in STATUSES if v in statuses]
        if _GRADUATING.search(sq) and not _UNIV_STUDENT.search(sq):
            unresolved.append({"evidence": sq, "note": None})  # 졸업 예정자는 재학 상태로 판정할 수 없다 (D-046)
        elif _GRADUATING.search(sq):
            # '대학생, 졸업예정자'처럼 대학생과 함께 적힌 졸업 예정은 대상을 넓히는 말: 재학·휴학 대학생은 해당
            conditions.append({"field": "enrollment_status", "operator": "in", "value": ["enrolled", "on_leave"],
                               "evidence": sq, "validation_status": "validated"})
        elif values and len(values) < len(STATUSES):
            conditions.append({"field": "enrollment_status", "operator": "in", "value": values, "evidence": sq,
                               "validation_status": "validated"})
    if target and not any(c["field"] == "enrollment_status" for c in conditions)             and not (_GRADUATING.search(target) and not _UNIV_STUDENT.search(target))             and not (isinstance(statuses, list) and statuses and _GRADUATING.search(sq or "") is None):
        if _UNIV_STUDENT.search(target):
            conditions.append({"field": "enrollment_status", "operator": "in", "value": ["enrolled", "on_leave"],
                               "evidence": target, "validation_status": "validated"})
    school = _value(entry, "school_only")
    if isinstance(school, str) and school.strip():
        unresolved.append({"evidence": _quote(entry, "school_only") or f"{school.strip()[:40]} 학생만", "note": None})
    for limit in entry.get("other_limits") or []:
        q = limit.get("quote") if isinstance(limit, dict) else None
        if isinstance(q, str) and q.strip() and not _TEAM_RULE.search(q):
            unresolved.append({"evidence": " ".join(q.split())[:QUOTE_MAX], "note": None})
    open_q = _quote(entry, "open_to_all")
    if not open_q and target and _ANYONE.search(target) and not _UNIV_STUDENT.search(target):
        open_q = target  # '누구나'만 적힌 응모 대상
    unrestricted = (_value(entry, "open_to_all") is True or open_q == target) and bool(open_q) and not conditions         and not unresolved
    return {
        "conditions": conditions,
        "unresolved_conditions": unresolved,
        # 응모 대상 문장을 읽었으면 학년·학적·학교 칸은 그 문장에서 다 본 것으로 둔다. 못 읽었으면 불완전
        "extraction_complete": bool(target) or unrestricted,
        "explicitly_unrestricted": unrestricted,
        "unrestricted_evidence": open_q if unrestricted else None,
    }


def judge_items(items: list[dict], text: str, read_urls: list[str], profile: dict, today: date) -> tuple[list[dict], dict]:
    """원문 읽기 결과로 판정·마감·주최를 붙인다. (결과, 집계 {'read', 'excluded_not_met', 'dropped_past'})."""
    try:
        data = extract_json(text)
    except ReportFormatError:
        data = {}
    opened = {_norm_url(u) for u in read_urls}
    entries = {}
    for e in data.get("items") if isinstance(data.get("items"), list) else []:
        if isinstance(e, dict) and isinstance(e.get("url"), str) and e.get("opened") is not False \
                and _norm_url(e["url"]) in opened:
            entries.setdefault(_norm_url(e["url"]), e)
    stats = {"read": 0, "excluded_not_met": 0, "dropped_past": 0}
    out = []
    for item in items:
        item = {**item, "verdict": None, "target": None, "organizer": None, "read": False}
        entry = entries.get(_norm_url(item["url"]))
        if entry is not None:
            stats["read"] += 1
            item["read"] = True
            item["target"] = _quote(entry, "target")
            org = _value(entry, "organizer")
            if isinstance(org, str) and org.strip() and _quote(entry, "organizer"):
                item["organizer"] = " ".join(org.split())[:60]
            day = _parse_day(_value(entry, "deadline"))
            dq = _quote(entry, "deadline") or ""
            if day is not None and any(f in dq for f in _date_forms(day)):
                if day < today:
                    stats["dropped_past"] += 1
                    continue
                item["deadline"] = day.isoformat()
            verdict, _ = evaluate(eligibility_from_page(entry), profile)
            if verdict == "not_met":
                stats["excluded_not_met"] += 1
                continue
            item["verdict"] = verdict
        out.append(item)
    # 원문을 읽고 판정한 것(충족 → 확인 필요) → 읽지 못한 출처 확인 결과 → 출처 확인 안 된 결과
    out.sort(key=lambda i: (not i["verified"], not i["read"], VERDICT_ORDER.get(i["verdict"], 2)))
    return out, stats


def build_read_message(items: list[dict]) -> str:
    return "열 링크:\n" + "\n".join(i["url"] for i in items)


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
        excluded = 0
        read_cost = 0.0
        if items and hasattr(provider, "read_pages"):
            try:  # 원문 읽기는 덧붙이는 단계. 실패해도 검색 결과는 준다
                read = provider.read_pages(READ_PROMPT, build_read_message(items))
                _add_spend(deps, month, read.usage.cost_krw)
                read_cost = read.usage.cost_krw or 0.0
                items, jstats = judge_items(items, read.text, read.read_urls, profile, deps.today_kst())
            except Exception as exc:
                log.warning("external read failed harness=%s error=%s", EXTERNAL_VERSION, type(exc).__name__)
                usage = getattr(exc, "usage", None)
                if usage is not None:
                    _add_spend(deps, month, usage.cost_krw)
                items = [{**i, "verdict": None, "target": None, "organizer": None, "read": False} for i in items]
                jstats = {"read": 0, "excluded_not_met": 0, "dropped_past": 0, "read_failed": 1}
            excluded = jstats["excluded_not_met"]
            stats.update({f"j_{k}": v for k, v in jstats.items()})
        else:
            items = [{**i, "verdict": None, "target": None, "organizer": None, "read": False} for i in items]
    except Exception as exc:  # 원문·한 줄 입력은 로그에 남기지 않는다
        log.warning("external search failed harness=%s error=%s", EXTERNAL_VERSION, type(exc).__name__)
        usage = getattr(exc, "usage", None)
        if usage is not None:
            _add_spend(deps, month, usage.cost_krw)
        finish(False)
        raise AgentError("unavailable") from None
    charged = bool(items)
    finish(charged)  # 찾은 것이 없으면 환불
    log.info("external search done harness=%s provider=%s sources=%d %s cost_krw=%s read_cost_krw=%s charged=%s",
             EXTERNAL_VERSION, result.usage.provider, len(result.sources),
             " ".join(f"{k}={v}" for k, v in stats.items()), result.usage.cost_krw, read_cost, charged)
    return {"items": items, "charged": charged, "excluded_not_met": excluded, "searched_at": utc_z(now)}
