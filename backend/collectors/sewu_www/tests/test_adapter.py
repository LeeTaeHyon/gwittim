import json
from datetime import date
from pathlib import Path

from backend.analysis import build_notice
from backend.collectors import sewu_www
from backend.collectors.common import InMemoryStore, Outcome, ingest
from backend.collectors.common import external_cli
from backend.collectors.common.http_polite import PoliteClient, RobotsBlocked, RunLimits, LimitReached
from backend.collectors.sewu_www import SOURCE_ID, collect, parse_detail, parse_list
from backend.contracts import schema_errors
from backend.sources import source_config

HTML = Path(__file__).parent / "html"
LIST = (HTML / "list.html").read_text(encoding="utf-8")
VIEW = (HTML / "view.html").read_text(encoding="utf-8")
POSTER = (HTML / "view_poster.html").read_text(encoding="utf-8")
AT = "2026-11-22T03:00:00Z"

PAGES = {"mode=list": LIST, "articleNo=9900001": VIEW, "articleNo=9900002": VIEW, "articleNo=9900003": POSTER}


class FakeClient:
    def __init__(self, pages: dict[str, str] = PAGES, stop_after: int | None = None):
        self.pages, self.calls, self.stop_after = pages, [], stop_after

    def fetch(self, url, kind="detail"):
        if self.stop_after is not None and len(self.calls) >= self.stop_after:
            raise LimitReached("site", "테스트 상한")
        self.calls.append((url, kind))
        for key, html in self.pages.items():
            if key in url:
                return html
        raise RobotsBlocked(url)


def test_parse_list_reads_rows_and_keeps_category_and_department():
    rows = parse_list(LIST)
    assert [r.article_no for r in rows] == ["9900001", "9900002", "9900003", "9900001"]
    first = rows[0]
    assert first.title == "[합성] 고정 공지 안내"  # '[공지]' 표시는 제목이 아님
    assert first.pinned and first.category == "교무 · 학사" and first.department == "합성교무처"
    assert first.posted_date == "2026-11-20"
    assert rows[1].category == "장학 · 대출" and not rows[1].pinned


def test_parse_detail_body_attachments_and_privacy():
    d = parse_detail(VIEW)
    assert d.title == "[합성] 교내 장학금 신청 안내"
    assert d.department == "합성학생처" and d.posted_date == "2026-11-18"
    assert d.attachments == [
        ("신청서 양식.hwp", "?mode=download&articleNo=9900002&attachNo=7700001"),
        ("안내문.pdf", "?mode=download&articleNo=9900002&attachNo=7700002"),
    ]
    assert "신청 기간: 2026.11.20.(금) ~ 12.04.(금) 17시" in d.body_text
    assert "재학생 전원" in d.body_text and "var x" not in d.body_text
    assert d.body_image_count == 1
    assert "203.0.113.7" not in repr(d) and "490" not in repr(d)  # IP·조회수 칸은 읽지 않음


def test_raw_notice_fields_and_contract():
    res = collect(FakeClient(), pages=1, collected_at=AT)
    raw = next(r for r in res.raws if r["source_notice_id"] == "9900002")
    assert schema_errors("raw_notice", raw) == []
    assert raw["source_id"] == SOURCE_ID
    assert raw["source_url"] == "https://www.sewu.ac.kr/sewu/news/notice.do?mode=view&articleNo=9900002"
    assert raw["published"] == {
        "date": "2026-11-18", "time": None, "timezone": None, "precision": "date", "evidence": "등록일 2026-11-18"
    }
    assert raw["source_fields"]["board_category"] == "장학 · 대출"
    assert raw["source_fields"]["author_department"] == "합성학생처"
    assert raw["attachments"][0]["file_name"] == "신청서 양식.hwp"
    assert raw["attachments"][0]["url"] == "https://www.sewu.ac.kr/sewu/news/notice.do?mode=download&articleNo=9900002&attachNo=7700001"
    assert raw["attachments"][0]["type"] == "hwp"
    assert "sample@example.invalid" not in raw["body_text"] and "[이메일 생략]" in raw["body_text"]
    dumped = json.dumps(raw, ensure_ascii=False)
    assert "203.0.113.7" not in dumped


def test_body_images_are_never_requested():
    client = FakeClient()
    collect(client, pages=1, collected_at=AT)
    assert client.calls and not any("/_attach" in u for u, _ in client.calls)
    assert [k for _, k in client.calls] == ["list", "detail", "detail", "detail"]  # 중복 번호(9900001)는 한 번만


def test_poster_only_notice_keeps_short_body():
    res = collect(FakeClient(), pages=1, collected_at=AT)
    raw = next(r for r in res.raws if r["source_notice_id"] == "9900003")
    assert raw["body_text"] == "" and raw["source_fields"]["body_image_count"] == 1
    assert schema_errors("raw_notice", raw) == []


def test_known_notices_are_not_requested_again():
    client = FakeClient()
    res = collect(client, pages=1, known={"9900001", "9900002"}.__contains__, collected_at=AT)
    assert [r["source_notice_id"] for r in res.raws] == ["9900003"] and res.skipped_known == 2
    assert not any("9900001" in u or "9900002" in u for u, k in client.calls if k == "detail")


def test_max_items_caps_detail_requests():
    client = FakeClient()
    res = collect(client, pages=1, max_items=2, collected_at=AT)
    assert len(res.raws) == 2 and res.stopped and "max-items" in res.stopped
    assert [k for _, k in client.calls].count("detail") == 2


def test_stop_ends_collection_and_records_reason():
    res = collect(FakeClient(stop_after=2), pages=1, collected_at=AT)  # 목록 1 + 상세 1
    assert len(res.raws) == 1 and res.stopped == "테스트 상한"


def test_one_failed_detail_does_not_block_the_rest():
    res = collect(FakeClient({"mode=list": LIST, "articleNo=9900003": POSTER}), pages=1, collected_at=AT)
    assert [r["source_notice_id"] for r in res.raws] == ["9900003"] and len(res.errors) == 2


def test_empty_list_page_is_reported_as_possible_layout_change():
    res = collect(FakeClient({"mode=list": "<html></html>"}), pages=1)
    assert res.raws == [] and "0건" in res.errors[0]


def test_list_url_uses_offset_per_page():
    from backend.collectors.sewu_www.adapter import list_url

    assert "article.offset=0" in list_url(1) and "article.offset=10" in list_url(2)
    assert list_url(1).startswith("https://www.sewu.ac.kr/sewu/news/notice.do?mode=list")


def test_site_limit_of_polite_client_caps_list_pages():
    # 실제 요청기의 상한(목록 2페이지)이 어댑터 위에서도 지켜진다
    class Opener:
        def __init__(self):
            self.urls = []

        def __call__(self, request, timeout=None):
            self.urls.append(request.full_url)
            body = b"User-agent: *\nDisallow: /_attach\n" if request.full_url.endswith("/robots.txt") else LIST.encode()
            return _Resp(body)

    opener = Opener()
    client = PoliteClient(limits=RunLimits(list_pages_per_site=1), opener=opener, sleep=lambda s: None)
    res = collect(client, pages=2, max_items=0, collected_at=AT)
    assert opener.urls[0].endswith("/robots.txt") and len(opener.urls) == 2  # robots + 목록 1페이지
    assert res.stopped and "상한" in res.stopped


class _Resp:
    def __init__(self, body: bytes):
        self._b = body
        self.headers = {"Content-Type": "text/html; charset=utf-8"}

    def read(self, n=-1):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_dry_run_prints_counts_without_storing(monkeypatch, tmp_path, capsys):
    client = FakeClient()
    client.summary = lambda: {"requests": len(client.calls)}
    monkeypatch.setattr(external_cli, "PoliteClient", lambda **kw: client)
    external_cli.main(sewu_www, ["--dry-run", "--pages", "1", "--max-items", "2", "--data-dir", str(tmp_path)])
    out = json.loads(capsys.readouterr().out)
    assert out["dry_run"] and out["source_id"] == SOURCE_ID
    assert out["parsed"] == 2 and out["schema_valid"] == 2
    assert list(tmp_path.iterdir()) == []  # 저장·게시 없음


def test_notice_builds_with_date_precision_and_school_source():
    res = collect(FakeClient(), pages=1, collected_at=AT)
    store = InMemoryStore()
    raw = next(r for r in res.raws if r["source_notice_id"] == "9900002")
    assert ingest(raw, store).outcome is Outcome.NEW
    notice, _ = build_notice(store.records[f"{SOURCE_ID}:9900002"], today=date(2026, 11, 22))
    assert schema_errors("notice", notice) == []
    assert notice["published"]["precision"] == "date" and notice["published"]["timezone"] is None
    assert source_config(SOURCE_ID).university_id == "sewu"
