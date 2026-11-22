"""예의 바른 요청기 시험: 가짜 HTTP로 robots·간격·429/403 멈춤·실행당 상한을 확인한다. 실제 네트워크는 쓰지 않는다."""
import urllib.error
from datetime import date

import pytest

from backend.collectors.common.http_polite import (
    USER_AGENT,
    HttpFailure,
    LimitReached,
    PoliteClient,
    RobotsBlocked,
    RunLimits,
    SiteStopped,
    decode_body,
)

SITE = "https://a.example.invalid"
OTHER = "https://b.example.invalid"


class Clock:
    def __init__(self):
        self.t = 0.0
        self.sleeps: list[float] = []

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.t += seconds


class FakeResponse:
    def __init__(self, body: bytes, content_type="text/html; charset=utf-8"):
        self._body = body
        self.headers = {"Content-Type": content_type}

    def read(self, n=-1):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeNet:
    """url → 본문(str·bytes) 또는 상태 코드(int). 없는 URL은 404."""

    def __init__(self, pages: dict):
        self.pages = pages
        self.calls: list[str] = []
        self.agents: list[str] = []

    def __call__(self, request, timeout=None):
        self.calls.append(request.full_url)
        self.agents.append(request.get_header("User-agent"))
        page = self.pages.get(request.full_url, 404)
        if isinstance(page, int):
            raise urllib.error.HTTPError(request.full_url, page, "err", {}, None)
        return FakeResponse(page.encode() if isinstance(page, str) else page)


def make(pages, *, clock=None, **kw):
    clock = clock or Clock()
    net = FakeNet(pages)
    client = PoliteClient(opener=net, sleep=clock.sleep, clock=clock.now, **kw)
    return client, net, clock


def test_sends_bot_user_agent_on_every_request():
    client, net, _ = make({f"{SITE}/robots.txt": "", f"{SITE}/x": "ok"})
    assert client.fetch(f"{SITE}/x") == "ok"
    assert net.agents == [USER_AGENT, USER_AGENT]
    assert USER_AGENT.startswith("GwittimBot/") and "non-commercial" in USER_AGENT


def test_robots_is_read_first_and_blocked_path_is_never_requested():
    robots = "User-agent: *\nDisallow: /private/\n"
    client, net, _ = make({f"{SITE}/robots.txt": robots, f"{SITE}/ok": "ok", f"{SITE}/private/a": "secret"})
    assert client.fetch(f"{SITE}/ok") == "ok"
    with pytest.raises(RobotsBlocked):
        client.fetch(f"{SITE}/private/a")
    assert net.calls == [f"{SITE}/robots.txt", f"{SITE}/ok"]  # 막힌 경로는 요청하지 않음, robots는 한 번만
    assert client.summary()["robots_blocked"] == 1


def test_robots_rule_for_our_bot_name_applies():
    robots = "User-agent: GwittimBot\nDisallow: /\n\nUser-agent: *\nAllow: /\n"
    client, net, _ = make({f"{SITE}/robots.txt": robots})
    with pytest.raises(RobotsBlocked):
        client.fetch(f"{SITE}/x")
    assert net.calls == [f"{SITE}/robots.txt"]


def test_robots_is_read_again_in_each_run():
    pages = {f"{SITE}/robots.txt": "", f"{SITE}/x": "ok"}
    for _ in range(2):
        client, net, _clock = make(pages)
        client.fetch(f"{SITE}/x")
        assert net.calls[0] == f"{SITE}/robots.txt"


def test_robots_missing_404_means_allowed_but_unreadable_stops_site():
    client, net, _ = make({f"{SITE}/x": "ok"})  # robots.txt 404
    assert client.fetch(f"{SITE}/x") == "ok"
    client, net, _ = make({f"{SITE}/robots.txt": 500, f"{SITE}/x": "ok"})
    with pytest.raises(SiteStopped):
        client.fetch(f"{SITE}/x")
    assert net.calls == [f"{SITE}/robots.txt"]  # 읽지 못했으니 본 요청은 하지 않음


def test_robots_403_stops_site_for_the_day(tmp_path):
    state = tmp_path / "stops.json"
    client, net, _ = make({f"{SITE}/robots.txt": 403}, state_path=state)
    with pytest.raises(SiteStopped):
        client.fetch(f"{SITE}/x")
    client2, net2, _ = make({f"{SITE}/robots.txt": "", f"{SITE}/x": "ok"}, state_path=state)
    with pytest.raises(SiteStopped):
        client2.fetch(f"{SITE}/x")
    assert net2.calls == []


def test_same_site_requests_are_spaced_at_least_3_seconds():
    client, net, clock = make({f"{SITE}/robots.txt": "", f"{SITE}/1": "a", f"{SITE}/2": "b", f"{SITE}/3": "c"})
    for n in "123":
        client.fetch(f"{SITE}/{n}")
    assert len(net.calls) == 4  # robots + 3
    assert clock.sleeps and all(s >= 2.999 for s in clock.sleeps)
    assert len(clock.sleeps) == 3  # 요청 4건 사이의 간격 3번
    assert clock.t >= 9.0


def test_different_sites_are_spaced_independently():
    client, _, clock = make({f"{SITE}/robots.txt": "", f"{OTHER}/robots.txt": "", f"{SITE}/1": "a", f"{OTHER}/1": "b"})
    client.fetch(f"{SITE}/1")  # 같은 사이트 robots → 본 요청 사이에서만 쉼
    slept = len(clock.sleeps)
    client.fetch(f"{OTHER}/1")
    assert len(clock.sleeps) == slept + 1  # OTHER는 robots → 본 요청 사이 한 번만 (SITE 요청 때문에 더 쉬지 않음)


def test_crawl_delay_longer_than_3_seconds_is_followed():
    robots = "User-agent: *\nCrawl-delay: 10\n"
    client, _, clock = make({f"{SITE}/robots.txt": robots, f"{SITE}/1": "a"})
    client.fetch(f"{SITE}/1")
    assert clock.sleeps == [10.0]  # robots 다음 본 요청 전에 Crawl-delay만큼


@pytest.mark.parametrize("status", [429, 403])
def test_429_or_403_stops_that_site_for_the_day(status, tmp_path):
    state = tmp_path / "stops.json"
    day = {"d": date(2026, 11, 21)}
    pages = {f"{SITE}/robots.txt": "", f"{SITE}/1": status, f"{SITE}/2": "ok", f"{OTHER}/robots.txt": "", f"{OTHER}/1": "ok"}
    client, net, _ = make(pages, state_path=state, today=lambda: day["d"])
    with pytest.raises(SiteStopped):
        client.fetch(f"{SITE}/1")
    n = len(net.calls)
    with pytest.raises(SiteStopped):
        client.fetch(f"{SITE}/2")
    assert len(net.calls) == n  # 멈춘 뒤에는 요청하지 않음
    assert client.fetch(f"{OTHER}/1") == "ok"  # 다른 사이트는 계속

    # 같은 날 다음 실행도 멈춰 있고, 다음 날은 풀린다
    client2, net2, _ = make(pages, state_path=state, today=lambda: day["d"])
    with pytest.raises(SiteStopped):
        client2.fetch(f"{SITE}/2")
    assert net2.calls == []
    day["d"] = date(2026, 11, 22)
    client3, _, _ = make(pages, state_path=state, today=lambda: day["d"])
    assert client3.fetch(f"{SITE}/2") == "ok"


def test_other_http_errors_fail_only_that_url():
    client, _, _ = make({f"{SITE}/robots.txt": "", f"{SITE}/1": 500, f"{SITE}/2": "ok"})
    with pytest.raises(HttpFailure) as e:
        client.fetch(f"{SITE}/1")
    assert e.value.status == 500
    assert client.fetch(f"{SITE}/2") == "ok"


def test_per_site_limits_list_pages_and_details():
    pages = {f"{SITE}/robots.txt": ""} | {f"{SITE}/l{i}": "x" for i in range(5)} | {f"{SITE}/d{i}": "x" for i in range(5)}
    client, net, _ = make(pages, limits=RunLimits(list_pages_per_site=2, details_per_site=3))
    client.fetch(f"{SITE}/l0", "list")
    client.fetch(f"{SITE}/l1", "list")
    with pytest.raises(LimitReached) as e:
        client.fetch(f"{SITE}/l2", "list")
    assert e.value.scope == "site"
    for i in range(3):
        client.fetch(f"{SITE}/d{i}", "detail")
    with pytest.raises(LimitReached):
        client.fetch(f"{SITE}/d3", "detail")
    assert len(net.calls) == 1 + 2 + 3  # 상한을 넘은 요청은 나가지 않음
    assert client.summary()["events"]  # 넘으면 기록


def test_total_request_limit_ends_the_run_including_robots():
    pages = {f"{SITE}/robots.txt": "", f"{OTHER}/robots.txt": ""} | {f"{SITE}/{i}": "x" for i in range(10)} | {f"{OTHER}/1": "x"}
    client, net, _ = make(pages, limits=RunLimits(total_requests=3))
    client.fetch(f"{SITE}/1")
    client.fetch(f"{SITE}/2")  # robots + 2 = 3건
    with pytest.raises(LimitReached) as e:
        client.fetch(f"{SITE}/3")
    assert e.value.scope == "run"
    with pytest.raises(LimitReached):
        client.fetch(f"{OTHER}/1")  # 다른 사이트도 실행 전체가 끝남
    assert len(net.calls) == 3


def test_run_time_limit_ends_the_run():
    client, net, clock = make({f"{SITE}/robots.txt": "", f"{SITE}/1": "a", f"{SITE}/2": "b"}, limits=RunLimits(seconds=60))
    client.fetch(f"{SITE}/1")
    clock.t += 61
    with pytest.raises(LimitReached) as e:
        client.fetch(f"{SITE}/2")
    assert e.value.scope == "run" and "시간" in e.value.reason


def test_redirect_must_stay_on_same_site_and_allowed_paths():
    robots = "User-agent: *\nDisallow: /private/\n"
    client, _, _ = make({f"{SITE}/robots.txt": robots, f"{SITE}/x": "ok"})
    client.fetch(f"{SITE}/x")
    assert client._redirect_ok(f"{SITE}/x", f"{SITE}/y")
    assert not client._redirect_ok(f"{SITE}/x", f"{OTHER}/y")
    assert not client._redirect_ok(f"{SITE}/x", f"{SITE}/private/y")


def test_decode_body_uses_header_then_meta_charset():
    text = "공모전 안내"
    assert decode_body(text.encode("euc-kr"), "text/html; charset=EUC-KR") == text
    assert decode_body(b'<meta charset="euc-kr">' + text.encode("euc-kr"), "text/html").endswith(text)
    assert decode_body(text.encode("utf-8"), None) == text
