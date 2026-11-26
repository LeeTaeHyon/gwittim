from pathlib import Path

from backend.collectors import wevity, wevity_activity
from backend.collectors.common.http_polite import RobotsBlocked
from backend.contracts import schema_errors

HTML = Path(__file__).parent / "html"
WEVITY = Path(wevity.__file__).parent / "tests" / "html"
LIST = (HTML / "list_active.html").read_text(encoding="utf-8")
PAGES = {
    "gp=1": LIST,
    "ix=900001": (WEVITY / "view.html").read_text(encoding="utf-8"),
    "ix=900002": (WEVITY / "view_minor.html").read_text(encoding="utf-8"),
}


class FakeClient:
    def __init__(self):
        self.calls = []

    def fetch(self, url, kind="detail"):
        self.calls.append((url, kind))
        for key, html in PAGES.items():
            if key in url:
                return html
        raise RobotsBlocked(url)


def test_parse_list_cards():
    rows = wevity_activity.parse_list(LIST)
    assert [r.ix for r in rows] == ["900001", "900002", "900003"]  # 메뉴 링크 제외
    assert rows[0].title == "[합성 샘플] 대학생 서포터즈" and rows[0].fields == "대외활동/서포터즈"
    assert [r.ended for r in rows] == [False, False, True]  # D+3은 마감, D-5는 열림


def test_collect():
    client = FakeClient()
    res = wevity_activity.collect(client, pages=1, collected_at="2026-11-26T03:00:00Z")
    assert [r["source_notice_id"] for r in res.raws] == ["900001"] and list(res.excluded) == ["900002"] and res.ended == 1
    assert not any("900003" in u for u, _ in client.calls)
    raw = res.raws[0]
    assert schema_errors("raw_notice", raw) == []
    assert raw["source_id"] == "wevity_activity" and "c=active" in raw["source_url"]
    assert "혜택:" in raw["body_text"] and "총 상금" not in raw["body_text"]
    assert raw["source_fields"]["category_hint"] == "extracurricular"
