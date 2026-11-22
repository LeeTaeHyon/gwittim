from datetime import date
from pathlib import Path

from backend.analysis import build_notice
from backend.collectors.common import InMemoryStore, Outcome, ingest
from backend.collectors.common.http_polite import RobotsBlocked
from backend.collectors.contestkorea import SOURCE_ID, collect, parse_detail, parse_list
from backend.contracts import schema_errors
from backend.sources import source_config

HTML = Path(__file__).parent / "html"
LIST = (HTML / "list.html").read_text(encoding="utf-8")
VIEW = (HTML / "view.html").read_text(encoding="utf-8")
AT = "2026-11-21T03:00:00Z"


class FakeClient:
    def __init__(self, pages):
        self.pages, self.calls = pages, []

    def fetch(self, url, kind="detail"):
        self.calls.append((url, kind))
        for key, html in self.pages.items():
            if key in url:
                return html
        raise RobotsBlocked(url)


PAGES = {"list.php": LIST, "str_no=900000000001": VIEW, "str_no=900000000004": VIEW}


def test_parse_list_reads_only_main_list():
    rows = parse_list(LIST)
    assert [r.str_no for r in rows] == ["900000000001", "900000000002", "900000000003", "900000000004"]
    r = rows[0]
    assert (r.title, r.category, r.host, r.audience, r.status, r.bcode) == (
        "[합성 샘플] 대학생 디자인 공모전", "미술•디자인•웹툰", "합성주최A", "대학생, 대학원생", "접수중", "030610001"
    )
    assert [r.ended for r in rows] == [False, False, True, False]  # 심사대기는 끝남, 마감임박은 열림


def test_parse_detail_drops_site_ai_text_and_contacts():
    d = parse_detail(VIEW)
    assert d.title == "[합성 샘플] 대학생 디자인 공모전"
    assert d.info["접수기간"] == "2026.12.01 ~ 2026.12.20"
    assert d.links == {"홈페이지": "http://example.invalid/notice/1", "접수하기": "https://example.invalid/apply"}
    assert "AI" not in d.body_text and "합성 AI" not in d.body_text
    assert "해시태그" not in d.body_text and "합성SNS" not in d.body_text
    assert "합성 소개 문장입니다." in d.body_text and "2026년 12월 1일(화)" in d.body_text
    assert "sample@example.invalid" not in d.body_text and "02-123-4567" not in d.body_text
    assert d.body_image_count == 1  # 본문 포스터 1장만. 상단 표·SNS 아이콘은 세지 않음


def test_collect_skips_ended_and_minor_rows_without_detail_request():
    client = FakeClient(PAGES)
    res = collect(client, pages=1, collected_at=AT)
    assert [r["source_notice_id"] for r in res.raws] == ["900000000001", "900000000004"]  # 대상 '기타'는 애매해서 포함
    assert list(res.excluded) == ["900000000002"] and res.ended == 1
    requested = [u for u, k in client.calls if k == "detail"]
    assert len(requested) == 2
    assert not any("900000000002" in u or "900000000003" in u for u in requested)
    for raw in res.raws:
        assert schema_errors("raw_notice", raw) == []
        assert raw["source_url"].startswith("https://www.contestkorea.com/sub/view.php?")
        assert raw["published"] is None and raw["source_id"] == SOURCE_ID


def test_list_url_uses_university_category_and_page():
    client = FakeClient(PAGES)
    collect(client, pages=1, max_items=0)
    assert "Txt_code1[0]=30" in client.calls[0][0] and client.calls[0][0].endswith("page=1")


def test_notice_dates_have_null_time_when_no_clock_in_period():
    res = collect(FakeClient(PAGES), pages=1, collected_at=AT)
    store = InMemoryStore()
    assert ingest(res.raws[0], store).outcome is Outcome.NEW
    notice, issues = build_notice(store.records[f"{SOURCE_ID}:900000000001"], today=date(2026, 11, 21))
    assert issues == [] and schema_errors("notice", notice) == []
    d = notice["application_deadline"]
    assert d["date"] == "2026-12-20" and d["time"] is None and d["timezone"] is None
    assert source_config(SOURCE_ID).name == "콘테스트코리아"
