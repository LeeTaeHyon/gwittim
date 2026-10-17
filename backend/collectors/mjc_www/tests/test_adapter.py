from datetime import date
from pathlib import Path

from backend.analysis import build_notice
from backend.collectors.common import InMemoryStore, Outcome, ingest
from backend.collectors.mjc_www import BOARDS, collect, parse_detail, parse_list
from backend.contracts import schema_errors

HTML = Path(__file__).parent / "html"
LIST = (HTML / "list.html").read_text(encoding="utf-8")
VIEW = (HTML / "view.html").read_text(encoding="utf-8")
BOARD = BOARDS["mjc_www_notice"]
AT = "2026-10-17T03:00:00Z"


def fake_fetch(pages: dict[str, str]):
    calls = []

    def fetch(url: str) -> str:
        calls.append(url)
        for key, html in pages.items():
            if key in url:
                return html
        raise OSError("not found")

    return fetch, calls


def test_parse_list_rows():
    rows = parse_list(LIST)
    assert [(r.data_idx, r.pinned, r.posted_date, r.author) for r in rows] == [
        ("BD9000000002", True, "2026-10-15", "합성부서"),
        ("BD9000000001", False, "2026-10-10", "합성팀"),
        ("BD9000000002", True, "2026-10-15", "합성부서"),
    ]
    assert rows[0].title == "[합성 샘플] 고정 공지 <경진대회> 안내"


def test_parse_detail():
    d = parse_detail(VIEW)
    assert d.title == "[합성 샘플] 고정 공지 <경진대회> 안내"
    assert (d.author, d.posted_date) == ("합성부서", "2026-10-15")
    assert d.attachments == ["[합성] 참가신청서.hwp"]  # 주석 속 예전 첨부 제외
    assert d.body_image_count == 1  # 주석 속 이미지 제외
    assert "운영대상: 우리대학 2~3학년 재학생" in d.body_text
    assert "2026.10.20.(화) ~ 2026.11.02.(월)" in d.body_text
    assert "test@example.invalid" not in d.body_text and "[이메일 생략]" in d.body_text
    assert "목록" not in d.body_text and "fn_egov" not in d.body_text


def test_collect_dedupes_pinned_and_outputs_valid_raw_notice():
    fetch, calls = fake_fetch({"list.do": LIST, "view.do": VIEW})
    raws, errors = collect(BOARD, fetch=fetch, delay=0, collected_at=AT)
    assert errors == []
    assert [r["source_notice_id"] for r in raws] == ["BD9000000002", "BD9000000001"]
    assert len(calls) == 3  # 목록 1 + 상세 2 (고정 공지 중복 요청 없음)
    raw = raws[0]
    assert schema_errors("raw_notice", raw) == []
    assert raw["published"] == {"date": "2026-10-15", "time": None, "timezone": None, "precision": "date", "evidence": "날짜 2026-10-15"}
    assert raw["attachments"] == [{"file_name": "[합성] 참가신청서.hwp", "url": None, "type": "hwp"}]
    assert "83" not in str(raw["source_fields"])  # 조회수 미포함
    assert raw["source_url"].endswith("menu_idx=66&bbs_mst_idx=BM0000000026&data_idx=BD9000000002")


def test_detail_failure_does_not_stop_others():
    def fetch(url):
        if "BD9000000002" in url:
            raise OSError("timeout")
        return LIST if "list.do" in url else VIEW

    raws, errors = collect(BOARD, fetch=fetch, delay=0, collected_at=AT)
    assert [r["source_notice_id"] for r in raws] == ["BD9000000001"]
    assert errors == ["BD9000000002: OSError"]


def test_recollect_is_unchanged_and_flows_into_analysis():
    fetch, _ = fake_fetch({"list.do": LIST, "view.do": VIEW})
    store = InMemoryStore()
    first, _ = collect(BOARD, fetch=fetch, delay=0, collected_at=AT)
    again, _ = collect(BOARD, fetch=fetch, delay=0, collected_at="2026-10-17T06:00:00Z")
    assert [ingest(r, store).outcome for r in first] == [Outcome.NEW, Outcome.NEW]
    assert [ingest(r, store).outcome for r in again] == [Outcome.UNCHANGED, Outcome.UNCHANGED]

    record = store.records["mjc_www_notice:BD9000000002"]
    notice, issues = build_notice(record, today=date(2026, 10, 17))
    assert issues == []
    assert notice["application_deadline"]["date"] == "2026-11-02"
    assert {c["field"] for c in notice["eligibility"]["conditions"]} == {"grade", "enrollment_status", "university_id"}
    assert notice["eligibility"]["extraction_complete"] is False  # 첨부·포스터 이미지


def test_only_notice_board_active_in_p0():
    assert [b.source_id for b in BOARDS.values() if b.active] == ["mjc_www_notice"]


# ---------- D-006 재시도 ----------

class _FakeResponse:
    def __init__(self, body: str):
        self.body = body.encode("utf-8")

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _http_error(code):
    import urllib.error

    return urllib.error.HTTPError("https://x", code, "err", {}, None)


def test_retries_transient_errors_then_succeeds(monkeypatch):
    import urllib.error

    from backend.collectors.mjc_www import adapter

    outcomes = [urllib.error.URLError("down"), _http_error(503), _FakeResponse("ok")]
    monkeypatch.setattr(adapter.urllib.request, "urlopen", lambda req, timeout: _pop(outcomes))
    waits = []
    assert adapter.http_fetch("https://x", sleep=waits.append) == "ok"
    assert waits == [5.0, 15.0]


def test_gives_up_after_two_retries(monkeypatch):
    from backend.collectors.mjc_www import adapter

    outcomes = [_http_error(500), _http_error(502), _http_error(503)]
    monkeypatch.setattr(adapter.urllib.request, "urlopen", lambda req, timeout: _pop(outcomes))
    waits = []
    try:
        adapter.http_fetch("https://x", sleep=waits.append)
        raise AssertionError("should raise")
    except Exception as e:
        assert getattr(e, "code", None) == 503
    assert waits == [5.0, 15.0]


def test_no_retry_on_404_or_403(monkeypatch):
    from backend.collectors.mjc_www import adapter

    for code in (403, 404):
        outcomes = [_http_error(code)]
        monkeypatch.setattr(adapter.urllib.request, "urlopen", lambda req, timeout: _pop(outcomes))
        waits = []
        try:
            adapter.http_fetch("https://x", sleep=waits.append)
        except Exception as e:
            assert e.code == code
        assert waits == []


def _pop(outcomes):
    item = outcomes.pop(0)
    if isinstance(item, Exception):
        raise item
    return item
