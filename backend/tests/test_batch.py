"""배치 한 번 실행(수집 → 분석 → 게시 → 사라진 공고 확인)을 합성 HTML로 검증한다."""
import urllib.error
from datetime import date
from pathlib import Path

from backend.batch import run_batch
from backend.collectors.common import InMemoryStore
from backend.collectors.mjc_www import BOARDS
from backend.collectors.mjc_www.adapter import probe
from backend.contracts import schema_errors
from backend.publish import InMemorySink

BOARD = BOARDS["mjc_www_notice"]
VIEW = (Path(__file__).resolve().parents[1] / "collectors/mjc_www/tests/html/view.html").read_text(encoding="utf-8")
TODAY = date(2026, 10, 17)


def list_html(rows: list[tuple[str, str]]) -> str:
    """rows: (data_idx, 게시일). 위에서부터 최신 순."""
    trs = "".join(
        f"<tr><td>{i}</td><td class='cell_type01'><a href=\"javascript:fn_view('BM0000000026','{d}','');\">[합성 샘플] 공지 {d}</a></td>"
        f"<td></td><td>합성팀</td><td>{posted}</td><td>1</td></tr>"
        for i, (d, posted) in enumerate(rows)
    )
    return f"<table><tbody>{trs}</tbody></table>"


def view_html(data_idx: str, posted: str) -> str:
    return VIEW.replace("[합성 샘플] 고정 공지 &lt;경진대회&gt; 안내", f"[합성 샘플] 공지 {data_idx}").replace("2026-10-15", posted)


class Site:
    def __init__(self, rows):
        self.rows = rows
        self.probes: dict[str, str] = {}
        self.probed: list[str] = []

    def fetch(self, url):
        if "list.do" in url:
            return list_html(self.rows)
        data_idx = url.rsplit("data_idx=", 1)[1]
        posted = dict(self.rows)[data_idx]
        return view_html(data_idx, posted)

    def probe(self, url):
        data_idx = url.rsplit("data_idx=", 1)[1]
        self.probed.append(data_idx)
        return self.probes.get(data_idx, "found")


def run(site, store, sink, notices):
    return run_batch([BOARD], store=store, sink=sink, notices=notices, today=TODAY, pages=1,
                     fetch=site.fetch, probe_fn=site.probe, delay=0)


def test_batch_collects_analyzes_and_publishes():
    site = Site([("BD3", "2026-10-15"), ("BD2", "2026-10-14"), ("BD1", "2026-10-13")])
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    report = run(site, store, sink, notices)
    assert (report.collected, report.published, report.queued) == (3, 3, 0)
    assert all(schema_errors("notice", n) == [] for n in sink.public.values())
    again = run(site, store, sink, notices)
    assert again.outcomes["unchanged"] == 3 and again.skipped == 3 and again.probed == 0


def test_removed_after_three_consecutive_not_found_runs():
    site = Site([("BD3", "2026-10-15"), ("BD2", "2026-10-14"), ("BD1", "2026-10-13")])
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    run(site, store, sink, notices)

    site.rows = [("BD3", "2026-10-15"), ("BD1", "2026-10-13")]  # BD2가 목록 범위 안에서 사라짐
    site.probes["BD2"] = "not_found"
    key = "mjc_www_notice:BD2"
    nid = notices[key]["notice_id"]

    for expected in (1, 2):
        report = run(site, store, sink, notices)
        assert report.removed == 0 and store.get(key).consecutive_not_found == expected
        assert sink.public[nid]["lifecycle_status"] != "removed"

    report = run(site, store, sink, notices)
    assert report.removed == 1
    removed = sink.public[nid]
    assert removed["lifecycle_status"] == "removed" and "lifecycle_status" in removed["changed_fields"]
    assert schema_errors("notice", removed) == []

    site.probed.clear()
    run(site, store, sink, notices)
    assert "BD2" not in site.probed  # 확정 후에는 더 확인하지 않음


def test_transient_error_and_reappearance_do_not_remove():
    site = Site([("BD3", "2026-10-15"), ("BD2", "2026-10-14"), ("BD1", "2026-10-13")])
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    run(site, store, sink, notices)
    key = "mjc_www_notice:BD2"

    site.rows = [("BD3", "2026-10-15"), ("BD1", "2026-10-13")]
    site.probes["BD2"] = "not_found"
    run(site, store, sink, notices)
    site.probes["BD2"] = "error"  # 일시 오류: 횟수 그대로
    run(site, store, sink, notices)
    assert store.get(key).consecutive_not_found == 1

    site.rows = [("BD3", "2026-10-15"), ("BD2", "2026-10-14"), ("BD1", "2026-10-13")]  # 다시 보임
    run(site, store, sink, notices)
    assert store.get(key).consecutive_not_found == 0 and not store.get(key).removed


def test_old_notices_outside_window_are_not_probed():
    site = Site([("BD3", "2026-10-15"), ("BD2", "2026-10-14"), ("BD1", "2026-10-13")])
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    run(site, store, sink, notices)
    site.rows = [("BD5", "2026-10-17"), ("BD4", "2026-10-16"), ("BD3", "2026-10-15")]  # 새 글로 밀려남
    report = run(site, store, sink, notices)
    assert report.probed == 0


# ---------- probe ----------

class _Resp:
    def __init__(self, url):
        self.url = url

    def geturl(self):
        return self.url

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_probe_detects_error_redirect_and_404():
    ok = lambda req, timeout: _Resp("https://www.mjc.ac.kr/bbs/data/view.do?data_idx=BD1")
    redirected = lambda req, timeout: _Resp("https://www.mjc.ac.kr/error;jsessionid=x?menuDeffective=true")

    def raises(code):
        def opener(req, timeout):
            raise urllib.error.HTTPError(req.full_url, code, "x", {}, None)
        return opener

    def offline(req, timeout):
        raise urllib.error.URLError("down")

    assert probe("https://x/view.do", opener=ok) == "found"
    assert probe("https://x/view.do", opener=redirected) == "not_found"
    assert probe("https://x/view.do", opener=raises(404)) == "not_found"
    assert probe("https://x/view.do", opener=raises(500)) == "error"
    assert probe("https://x/view.do", opener=offline) == "error"
