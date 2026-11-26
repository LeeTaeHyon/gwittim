from datetime import date, datetime
from pathlib import Path

from backend.batch import run_external
from backend.collectors import linkareer_activity, linkareer_contest
from backend.collectors.common import InMemoryStore
from backend.collectors.common.http_polite import RobotsBlocked
from backend.collectors.linkareer import parser
from backend.contracts import schema_errors
from backend.publish import InMemorySink
from backend.sources import source_config

HTML = Path(__file__).parent / "html"
AT = "2026-11-26T03:00:00Z"
NOW_MS = int(datetime(2026, 11, 26, tzinfo=parser.KST).timestamp() * 1000)


def read(name: str) -> str:
    return (HTML / name).read_text(encoding="utf-8")


class FakeClient:
    def __init__(self, pages):
        self.pages, self.calls = pages, []

    def fetch(self, url, kind="detail"):
        self.calls.append((url, kind))
        for key, html in self.pages.items():
            if key in url:
                return html
        raise RobotsBlocked(url)


CONTEST_PAGES = {
    "list/contest": read("list_contest.html"),
    "activity/900101": read("view_contest.html"),
    "activity/900105": read("view_contest_minor.html"),
    "activity/900106": read("view_contest_noaudience.html"),
}
ACTIVITY_PAGES = {
    "list/activity": read("list_activity.html"),
    "activity/900201": read("view_activity.html"),
    "activity/900204": read("view_activity_asap.html"),
}


def test_ms_to_date_uses_korean_date_without_time():
    assert parser.ms_to_date(1796914799999) == "2026-12-10"
    assert parser.ms_to_date(None) is None


def test_parse_list_uses_main_list_only_and_type_filter():
    rows = parser.parse_list(read("list_contest.html"), now_ms=NOW_MS)
    assert [r.id for r in rows] == ["900101", "900103", "900105", "900106"]  # 사이드 추천(999999) 제외
    assert [r.ended for r in rows] == [False, True, False, False]
    act = parser.parse_list(read("list_activity.html"), now_ms=NOW_MS, type_id=parser.TYPE_ACTIVITY)
    assert [r.id for r in act] == ["900201", "900203", "900204"]  # 교육(6) 제외
    assert [r.ended for r in act] == [False, True, False]  # 충원 시 마감은 날짜로 거르지 않음


def test_parse_detail_drops_contacts():
    d = parser.parse_detail(read("view_contest.html"), "900101")
    assert d.targets == ["대학생", "일반인"] and d.categories == ["기획/아이디어"]
    assert d.recruit_start == "2026-12-01" and d.recruit_close == "2026-12-31" and d.reward_man == 500
    assert "sample@example.invalid" not in d.body_text and "02-123-4567" not in d.body_text
    assert "[이메일 생략]" in d.body_text and "[전화번호 생략]" in d.body_text and d.body_image_count == 1
    assert d.apply_url is None and d.homepage == "https://example.invalid/contest/1"
    assert parser.parse_detail("<html></html>", "1") is None


def run_collect(mod, pages, monkeypatch):
    monkeypatch.setattr(parser.time, "time", lambda: NOW_MS / 1000)
    client = FakeClient(pages)
    return mod.collect(client, pages=1, collected_at=AT), client


def test_contest_collect(monkeypatch):
    res, client = run_collect(linkareer_contest, CONTEST_PAGES, monkeypatch)
    assert [r["source_notice_id"] for r in res.raws] == ["900101", "900106"]
    assert list(res.excluded) == ["900105"] and res.ended == 1 and res.listed == 4
    assert not any("900103" in u for u, _ in client.calls)  # 마감 공고는 상세 요청 없음
    for raw in res.raws:
        assert schema_errors("raw_notice", raw) == []
        assert raw["source_id"] == "linkareer_contest" and raw["published"] is None
        assert raw["source_url"].startswith("https://linkareer.com/activity/")
    body = res.raws[0]["body_text"]
    assert "응모대상: 대학생, 일반인" in body and "접수기간: 2026-12-01 ~ 2026-12-31" in body and "총 상금: 500만원" in body
    assert res.raws[0]["source_fields"]["official_url"] == "https://example.invalid/contest/1"


def test_activity_collect_and_asap_deadline_not_confirmed(monkeypatch):
    res, _ = run_collect(linkareer_activity, ACTIVITY_PAGES, monkeypatch)
    assert [r["source_notice_id"] for r in res.raws] == ["900201", "900204"] and res.ended == 1
    asap = res.raws[1]
    assert "접수기간: 충원 시 마감(마감일 미확정)" in asap["body_text"] and "2027-06-30" not in asap["body_text"]
    assert asap["source_fields"]["application_period"] is None
    assert "모집대상: 대학생" in res.raws[0]["body_text"] and "모집인원: 10" in res.raws[0]["body_text"]
    assert "활동기간: 2027-01-01 ~ 2027-06-30" in res.raws[0]["body_text"]


def test_activity_category_not_forced_to_contest(monkeypatch):
    # 본문에 '대회'가 있어 규칙은 공모전으로 보지만, 대외활동 메뉴는 비교과(extracurricular)로 둔다
    res, _ = run_collect(linkareer_activity, ACTIVITY_PAGES, monkeypatch)
    notices: dict = {}
    run_external(res.raws, source_id="linkareer_activity", store=InMemoryStore(), sink=InMemorySink(), notices=notices, today=date(2026, 11, 26))
    assert notices["linkareer_activity:900201"]["category"] == "extracurricular"
    assert all(n["category"] != "contest" for n in notices.values())
    assert source_config("linkareer_activity").timezone is None


def test_contest_flow_to_public(monkeypatch):
    res, _ = run_collect(linkareer_contest, CONTEST_PAGES, monkeypatch)
    sink = InMemorySink()
    report = run_external(res.raws, source_id="linkareer_contest", store=InMemoryStore(), sink=sink, notices={}, today=date(2026, 11, 26))
    assert report.collected == 2 and report.published + report.queued == 2
    for n in sink.public.values():
        assert schema_errors("notice", n) == []
