from pathlib import Path

from backend.analysis import build_notice
from backend.collectors.common import InMemoryStore, Outcome, ingest
from backend.collectors.common.http_polite import LimitReached, RobotsBlocked
from backend.collectors.wevity import SOURCE_ID, collect, parse_detail, parse_list
from backend.contracts import schema_errors
from backend.sources import source_config

HTML = Path(__file__).parent / "html"
LIST = (HTML / "list.html").read_text(encoding="utf-8")
VIEW = (HTML / "view.html").read_text(encoding="utf-8")
MINOR = (HTML / "view_minor.html").read_text(encoding="utf-8")
NOAUD = (HTML / "view_noaudience.html").read_text(encoding="utf-8")
AT = "2026-11-21T03:00:00Z"


class FakeClient:
    def __init__(self, pages: dict[str, str], stop_after: int | None = None):
        self.pages, self.calls, self.stop_after = pages, [], stop_after

    def fetch(self, url, kind="detail"):
        if self.stop_after is not None and len(self.calls) >= self.stop_after:
            raise LimitReached("site", "테스트 상한")
        self.calls.append((url, kind))
        for key, html in self.pages.items():
            if key in url:
                return html
        raise RobotsBlocked(url)


PAGES = {"gp=1": LIST, "ix=900001": VIEW, "ix=900002": MINOR, "ix=900003": NOAUD}


def test_parse_list_reads_only_main_list():
    rows = parse_list(LIST)
    assert [r.ix for r in rows] == ["900001", "900002", "900003", "900004", "900001"]
    assert rows[0].title == "[합성 샘플] 대학생 아이디어 공모전"  # SPECIAL 표시 제외
    assert rows[0].fields == "기획/아이디어, 기타" and rows[0].organizer == "합성주최A"
    assert [r.ended for r in rows] == [False, False, False, True, False]  # 마감임박(soon)은 열려 있음


def test_parse_detail():
    d = parse_detail(VIEW)
    assert d.title == "[합성 샘플] 대학생 아이디어 공모전"
    assert d.info["응모대상"] == "대학생, 기타"
    assert d.info["접수기간"] == "2026-12-01 ~ 2026-12-31"  # D-day 표시 제외
    assert d.homepage == "https://example.invalid/contest/1"
    assert "참가조건" not in d.info and "공유" not in " ".join(d.info.values())  # 주석·sns 제외
    assert "sample@example.invalid" not in d.body_text and "[이메일 생략]" in d.body_text
    assert "02-123-4567" not in d.body_text and "[전화번호 생략]" in d.body_text
    assert d.body_image_count == 1


def test_collect_filters_ended_audience_and_dedups():
    client = FakeClient(PAGES)
    res = collect(client, pages=1, collected_at=AT)
    assert [r["source_notice_id"] for r in res.raws] == ["900001", "900003"]  # 청소년 전용(900002) 제외, 대상 미표기(900003)는 포함
    assert list(res.excluded) == ["900002"]
    assert res.ended == 1 and res.listed == 4
    assert [k for _, k in client.calls] == ["list", "detail", "detail", "detail"]  # 끝난 공고(900004)는 상세 요청 없음
    assert not any("900004" in u for u, _ in client.calls)
    for raw in res.raws:
        assert schema_errors("raw_notice", raw) == []
        assert raw["source_id"] == SOURCE_ID and raw["published"] is None
        assert raw["source_url"].startswith("https://www.wevity.com/")


def test_known_notices_are_not_requested_again():
    client = FakeClient(PAGES)
    res = collect(client, pages=1, known={"900001", "900002"}.__contains__, collected_at=AT)
    assert [r["source_notice_id"] for r in res.raws] == ["900003"]
    assert res.skipped_known == 2
    assert not any("ix=900001" in u or "ix=900002" in u for u, _ in client.calls)


def test_max_items_caps_detail_requests():
    client = FakeClient(PAGES)
    res = collect(client, pages=1, max_items=1, collected_at=AT)
    assert len(res.raws) == 1 and res.stopped and "max-items" in res.stopped
    assert [k for _, k in client.calls].count("detail") == 1


def test_stop_ends_collection_and_records_reason():
    client = FakeClient(PAGES, stop_after=2)  # 목록 1 + 상세 1
    res = collect(client, pages=1, collected_at=AT)
    assert len(res.raws) == 1 and res.stopped == "테스트 상한"


def test_one_failed_detail_does_not_block_the_rest():
    client = FakeClient({"gp=1": LIST, "ix=900003": NOAUD})  # 900001 상세는 robots 차단
    res = collect(client, pages=1, collected_at=AT)
    assert [r["source_notice_id"] for r in res.raws] == ["900003"]
    assert len(res.errors) == 2  # 900001, 900002


def test_empty_list_page_is_reported_as_possible_layout_change():
    res = collect(FakeClient({"gp=1": "<html></html>"}), pages=1)
    assert res.raws == [] and "0건" in res.errors[0]


def test_deadline_without_time_has_null_time_and_notice_validates():
    res = collect(FakeClient(PAGES), pages=1, collected_at=AT)
    store = InMemoryStore()
    raw = res.raws[0]
    assert ingest(raw, store).outcome is Outcome.NEW
    from datetime import date

    notice, issues = build_notice(store.records[f"{SOURCE_ID}:900001"], today=date(2026, 11, 21))
    assert issues == [] and notice["publication_status"] == "published"
    assert schema_errors("notice", notice) == []
    d = notice["application_deadline"]
    assert d["date"] == "2026-12-31" and d["time"] is None and d["precision"] == "date" and d["timezone"] is None
    assert notice["application_start"]["date"] == "2026-12-01"
    assert notice["lifecycle_status"] == "open"
    assert source_config(SOURCE_ID).name == "위비티" and source_config(SOURCE_ID).university_id is None
