"""예의 바른 요청기: 교외 출처 수집용 (D-038).

- 봇 이름과 비상업 목적을 User-Agent에 밝힌다(GwittimBot).
- 실행마다 사이트의 robots.txt를 먼저 읽고, 막힌 경로는 요청하지 않는다. robots.txt를 읽지 못하면(403·429·5xx·네트워크 오류) 그 사이트는 이번 실행에서 열지 않는다.
- 같은 사이트 요청 사이에 3초 이상 쉰다(robots의 Crawl-delay가 더 길면 그 값).
- 429·403을 받으면 그날 그 사이트를 멈춘다. 멈춤은 state_path에 남겨 같은 날 다음 실행에도 이어진다.
- 실행당 상한을 코드로 강제한다: 사이트별 목록 2페이지·상세 30건, 전체 HTTP 200건(robots.txt 포함), 실행 30분. 넘으면 Stop을 올려 그 실행(또는 그 사이트)을 끝낸다.
- 리다이렉트는 같은 사이트·robots 허용 경로로만 따라간다.

어댑터는 `client.fetch(url, kind)`만 쓰고, Stop(실행 종료)과 FetchError(그 URL만 실패)를 구분해 처리한다.
"""
from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit
from urllib.robotparser import RobotFileParser

BOT_NAME = "GwittimBot"
# 헤더는 ASCII만 가능하다. 연락처는 약관·처리방침의 문의처와 같다
USER_AGENT = "GwittimBot/0.1 (+non-commercial student project; contact: dlxogus0619@mjc.ac.kr)"
KST = timezone(timedelta(hours=9), "Asia/Seoul")
MAX_BODY_BYTES = 2_000_000
STOP_STATUSES = (403, 429)  # D-038: 그날 그 사이트 멈춤


@dataclass(frozen=True)
class RunLimits:
    """D-038 실행당 상한."""

    list_pages_per_site: int = 2
    details_per_site: int = 30
    total_requests: int = 200
    seconds: float = 30 * 60
    min_interval: float = 3.0


class FetchError(Exception):
    """이 URL만 실패. 다른 URL은 계속 시도해도 된다."""


class RobotsBlocked(FetchError):
    """robots.txt가 막은 경로라 요청하지 않았다."""


class HttpFailure(FetchError):
    def __init__(self, url: str, status: int | None, reason: str) -> None:
        super().__init__(f"{status or 'network'} {reason}")
        self.url, self.status, self.reason = url, status, reason


class Stop(Exception):
    """더 요청하지 않는다. 어댑터는 그 사이트 수집을 끝내고 사유를 기록한다."""

    def __init__(self, scope: str, reason: str) -> None:
        super().__init__(reason)
        self.scope, self.reason = scope, reason  # scope: "site" | "run"


class SiteStopped(Stop):
    def __init__(self, site: str, reason: str) -> None:
        super().__init__("site", f"{site}: {reason}")
        self.site = site


class LimitReached(Stop):
    pass


def _site(url: str) -> str:
    return urlsplit(url).netloc.lower()


def decode_body(data: bytes, content_type: str | None) -> str:
    """헤더 charset → meta charset → utf-8 순으로 읽는다. 깨진 글자는 대체 문자로 둔다."""
    charset = None
    if content_type and (m := re.search(r"charset=([\w-]+)", content_type, re.I)):
        charset = m[1]
    elif m := re.search(rb"<meta[^>]+charset=[\"']?([\w-]+)", data[:4096], re.I):
        charset = m[1].decode("ascii", "ignore")
    try:
        return data.decode(charset or "utf-8", "replace")
    except LookupError:
        return data.decode("utf-8", "replace")


class _SameSiteRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, allow: Callable[[str, str], bool]) -> None:
        self._allow = allow

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not self._allow(req.full_url, newurl):
            raise urllib.error.HTTPError(req.full_url, code, "redirect not allowed", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class PoliteClient:
    """한 번의 수집 실행 동안 쓰는 요청기. 실행마다 새로 만든다(robots.txt를 실행마다 다시 읽음)."""

    def __init__(
        self,
        *,
        limits: RunLimits = RunLimits(),
        state_path: Path | None = None,
        opener: Callable | None = None,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        today: Callable[[], date] = lambda: datetime.now(KST).date(),
        user_agent: str = USER_AGENT,
        timeout: float = 30.0,
    ) -> None:
        self.limits = limits
        self.user_agent = user_agent
        self.timeout = timeout
        self._state_path = Path(state_path) if state_path else None
        self._opener = opener or urllib.request.build_opener(_SameSiteRedirect(self._redirect_ok)).open
        self._sleep, self._clock, self._today = sleep, clock, today
        self._started = clock()
        self._last: dict[str, float] = {}
        self._robots: dict[str, RobotFileParser] = {}
        self._delay: dict[str, float] = {}
        self._used: dict[str, dict[str, int]] = {}
        self.requests = 0
        self.robots_blocked: list[str] = []
        self.events: list[str] = []  # 멈춤·상한 도달 기록

    # ---------- 공개 ----------

    def fetch(self, url: str, kind: str = "detail") -> str:
        """kind: "list" | "detail". 목록 페이지·상세 건수를 사이트별로 센다."""
        site = _site(url)
        self._check_run()
        self._check_stopped(site)
        robots = self._robots_for(url)
        if not robots.can_fetch(BOT_NAME, url):
            self.robots_blocked.append(url)
            raise RobotsBlocked(f"robots.txt가 막은 경로: {urlsplit(url).path}")
        self._count_site(site, kind)
        return self._get(url)

    def summary(self) -> dict:
        return {
            "requests": self.requests,
            "per_site": {site: dict(used) for site, used in self._used.items()},
            "robots_blocked": len(self.robots_blocked),
            "events": list(self.events),
        }

    # ---------- 상한·멈춤 ----------

    def _stop(self, exc: Stop) -> Stop:
        self.events.append(exc.reason)
        return exc

    def _check_run(self) -> None:
        if self._clock() - self._started >= self.limits.seconds:
            raise self._stop(LimitReached("run", f"실행 시간 {self.limits.seconds:.0f}초 상한"))
        if self.requests >= self.limits.total_requests:
            raise self._stop(LimitReached("run", f"전체 요청 {self.limits.total_requests}건 상한"))

    def _count_site(self, site: str, kind: str) -> None:
        used = self._used.setdefault(site, {"list": 0, "detail": 0})
        cap = self.limits.list_pages_per_site if kind == "list" else self.limits.details_per_site
        if used.setdefault(kind, 0) >= cap:
            raise self._stop(LimitReached("site", f"{site}: {kind} {cap}건 상한"))
        used[kind] += 1

    def _load_state(self) -> dict:
        if self._state_path and self._state_path.exists():
            try:
                return json.loads(self._state_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return {}
        return {}

    def _check_stopped(self, site: str) -> None:
        entry = self._load_state().get(site)
        if entry and entry.get("date") == self._today().isoformat():
            raise self._stop(SiteStopped(site, f"오늘 {entry.get('status')} 응답으로 멈춤"))

    def _mark_stopped(self, site: str, status: int | str) -> SiteStopped:
        if self._state_path:
            state = self._load_state()
            state[site] = {"date": self._today().isoformat(), "status": status}
            self._state_path.parent.mkdir(parents=True, exist_ok=True)
            self._state_path.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
        return self._stop(SiteStopped(site, f"{status} 응답으로 오늘 멈춤"))  # type: ignore[return-value]

    # ---------- robots.txt ----------

    def _robots_for(self, url: str) -> RobotFileParser:
        parts = urlsplit(url)
        site = parts.netloc.lower()
        if site in self._robots:
            return self._robots[site]
        robots_url = f"{parts.scheme}://{parts.netloc}/robots.txt"
        parser = RobotFileParser()
        try:
            text = self._get(robots_url)
            parser.parse(text.splitlines())
        except HttpFailure as e:
            if e.status is not None and 400 <= e.status < 500 and e.status not in STOP_STATUSES:
                parser.parse([])  # robots.txt 없음(404 등): 제한 없음 (RFC 9309)
            else:
                # 읽지 못했으니 허용으로 보지 않는다. 이번 실행에서는 그 사이트를 열지 않는다
                raise self._stop(SiteStopped(site, f"robots.txt를 읽지 못함({e.status or e.reason})")) from e
        self._robots[site] = parser
        delay = parser.crawl_delay(BOT_NAME)
        self._delay[site] = float(delay) if delay else 0.0
        return parser

    def _redirect_ok(self, old: str, new: str) -> bool:
        if _site(old) != _site(new):
            return False
        robots = self._robots.get(_site(new))
        return robots is None or robots.can_fetch(BOT_NAME, new)  # robots.txt 자신의 리다이렉트는 robots가 아직 없음

    # ---------- 실제 요청 ----------

    def _get(self, url: str) -> str:
        site = _site(url)
        if self.requests >= self.limits.total_requests:
            raise self._stop(LimitReached("run", f"전체 요청 {self.limits.total_requests}건 상한"))
        interval = max(self.limits.min_interval, self._delay.get(site, 0.0))
        last = self._last.get(site)
        if last is not None:
            wait = last + interval - self._clock()
            if wait > 0:
                self._sleep(wait)
        self.requests += 1
        self._last[site] = self._clock()
        request = urllib.request.Request(url, headers={"User-Agent": self.user_agent, "Accept-Language": "ko,en;q=0.5"})
        try:
            with self._opener(request, timeout=self.timeout) as resp:
                data = resp.read(MAX_BODY_BYTES)
                content_type = resp.headers.get("Content-Type") if getattr(resp, "headers", None) else None
        except urllib.error.HTTPError as e:
            if e.code in STOP_STATUSES:
                raise self._mark_stopped(site, e.code) from e
            raise HttpFailure(url, e.code, "HTTP 오류") from e
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            raise HttpFailure(url, None, type(e).__name__) from e
        finally:
            self._last[site] = self._clock()  # 간격은 응답을 받은 뒤부터 센다
        return decode_body(data, content_type)
