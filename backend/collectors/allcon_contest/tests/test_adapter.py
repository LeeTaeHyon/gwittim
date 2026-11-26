from pathlib import Path

from backend.collectors import allcon_contest
from backend.collectors.allcon_contest.parser import long_dates
from backend.contracts import schema_errors

HTML = Path(__file__).parent / "html"


def read(name: str) -> str:
    return (HTML / name).read_text(encoding="utf-8")


class FakeClient:
    def __init__(self):
        self.calls = []

    def fetch(self, url, kind="detail", *, form_body=None, json_body=None):
        self.calls.append((url, kind, form_body))
        if kind == "list":
            assert json_body is None and form_body is not None and url.endswith("/page/ajax.contest_list.php")
            return read("list_p1.json") if form_body["page"] == "1" else read("list_empty.json")
        return read("view_minor.html") if url.endswith("/900403") else read("view.html")


def test_long_dates():
    assert long_dates("26.11.09 ~ 26.11.30") == "2026-11-09 ~ 2026-11-30"
    assert long_dates("총 상금 250만원") == "총 상금 250만원"


def test_parse_list_and_detail():
    rows = allcon_contest.parse_list(read("list_p1.json"))
    assert [r.id for r in rows] == ["900401", "900402", "900403"]
    assert rows[0].title == "[합성 샘플] 대학생 영상 공모전" and rows[0].status == "접수중 D-4"
    assert [r.ended for r in rows] == [False, True, False]
    assert allcon_contest.parse_list("not json") == []
    d = allcon_contest.parse_detail(read("view.html"))
    assert d.title == "[합성 샘플] 대학생 영상 공모전" and d.info["응모대상"] == "일반인, 대학생, 대학원생"
    assert d.info["접수기간"] == "26.11.09 ~ 26.12.30" and d.apply_url == "https://example.invalid/apply"
    assert "lite-youtube" not in d.body_text and "합성 본문" in d.body_text
    assert "sample@example.invalid" not in d.body_text and "02-123-4567" not in d.body_text and d.body_image_count == 1


def test_collect_posts_form_and_skips_ended_and_minor():
    client = FakeClient()
    res = allcon_contest.collect(client, pages=1, collected_at="2026-11-26T03:00:00Z")
    assert [r["source_notice_id"] for r in res.raws] == ["900401"] and list(res.excluded) == ["900403"] and res.ended == 1
    assert not any("900402" in u for u, _, _ in client.calls)  # 마감은 상세 요청 없음
    raw = res.raws[0]
    assert schema_errors("raw_notice", raw) == []
    assert raw["source_id"] == "allcon_contest" and raw["source_url"] == "https://www.all-con.co.kr/view/contest/900401"
    assert "접수기간: 2026-11-09 ~ 2026-12-30" in raw["body_text"] and "응모대상: 일반인, 대학생, 대학원생" in raw["body_text"]
    assert raw["source_fields"]["official_url"] == "https://example.invalid/apply"
    assert client.calls[0][2]["t"] == "1" and client.calls[0][2]["rows"] == "15"


def test_backfill_ends_on_empty_page():
    client = FakeClient()
    res = allcon_contest.collect(client, backfill=True)
    assert res.pages_read == 2 and res.stopped is None and len(res.raws) == 1
