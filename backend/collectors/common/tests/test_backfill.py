"""백필(D-059, 수동 1회성 채우기)과 배치 상한 시험. 가짜 목록·요청기만 쓴다."""
import pytest

from backend.collectors.common import external_cli
from backend.collectors.common.external import BACKFILL_MAX_PAGES, ListDetailSource, collect_list_detail
from backend.collectors.common.http_polite import LimitReached, PoliteClient, RunLimits


class Row:
    def __init__(self, i, ended=False):
        self.i, self.ended = str(i), ended


def make_source(pages: dict[int, list[Row]]) -> ListDetailSource:
    return ListDetailSource(
        source_id="fake_x",
        list_url=lambda p: f"https://fake.invalid/list?p={p}",
        parse_list=lambda html: [Row(*r) for r in eval(html)],  # noqa: S307 (테스트 입력)
        row_id=lambda r: r.i,
        row_ended=lambda r: r.ended,
        row_audience=lambda r: None,
        detail_url=lambda r: f"https://fake.invalid/view?i={r.i}",
        build=lambda r, html: (f"공고 {r.i}", "본문", {"audience": "대학생"}),
    )


class Client:
    def __init__(self, pages, stop_after=None):
        self.pages, self.calls, self.stop_after = pages, [], stop_after

    def fetch(self, url, kind="detail"):
        if self.stop_after is not None and len(self.calls) >= self.stop_after:
            raise LimitReached("run", "요청 상한")
        self.calls.append((url, kind))
        if kind == "list":
            return repr(self.pages.get(int(url.rsplit("=", 1)[1]), []))
        return "<html/>"


def pages_of(n_pages, per=3, ended_from=None):
    out = {}
    for p in range(1, n_pages + 1):
        out[p] = [(f"{p}{k}", ended_from is not None and p >= ended_from) for k in range(per)]
    return out


def test_batch_mode_respects_pages_and_max_items():
    c = Client(pages_of(9))
    res = collect_list_detail(c, make_source({}), pages=5, max_items=7)
    assert len(res.raws) == 7 and res.stopped.startswith("상세 7건")
    c = Client(pages_of(9))
    res = collect_list_detail(c, make_source({}), pages=2, max_items=50)
    assert res.pages_read == 2 and len(res.raws) == 6


def test_backfill_has_no_item_cap_and_stops_at_list_end():
    c = Client(pages_of(8))
    res = collect_list_detail(c, make_source({}), backfill=True)
    assert len(res.raws) == 24 and res.pages_read == 9 and res.stopped is None and res.errors == []
    assert [k for _, k in c.calls].count("list") == 9  # 9쪽(빈 쪽)에서 끝을 확인


def test_backfill_stops_at_page_with_only_ended_rows():
    c = Client(pages_of(10, ended_from=4))
    res = collect_list_detail(c, make_source({}), backfill=True)
    assert len(res.raws) == 9 and res.pages_read == 4 and res.ended == 3
    assert not any("p=5" in u for u, _ in c.calls)


def test_backfill_stops_when_site_repeats_last_page():
    pages = {1: [("a", False)], 2: [("b", False)], 3: [("b", False)], 4: [("b", False)]}
    c = Client(pages)
    res = collect_list_detail(c, make_source({}), backfill=True)
    assert [r["source_notice_id"] for r in res.raws] == ["a", "b"] and res.pages_read == 3


def test_backfill_ends_on_stop_and_keeps_collected():
    c = Client(pages_of(8), stop_after=6)  # 목록 1 + 상세 3 + 목록 1 + 상세 1에서 상한
    res = collect_list_detail(c, make_source({}), backfill=True)
    assert res.stopped == "요청 상한" and 0 < len(res.raws) < 24


def test_backfill_page_safety_cap():
    pages = {p: [(f"{p}", False)] for p in range(1, BACKFILL_MAX_PAGES + 5)}
    res = collect_list_detail(Client(pages), make_source({}), backfill=True)
    assert res.pages_read == BACKFILL_MAX_PAGES


def run_cli(monkeypatch, tmp_path, argv, env=None):
    captured = {}

    class FakeClientCls(PoliteClient):
        def __init__(self, *, limits, state_path):
            captured["limits"] = limits
            super().__init__(limits=limits, state_path=state_path)

    class Mod:
        __name__ = "fake"
        SOURCE_ID = "fake_x"

        @staticmethod
        def collect(client, **kw):
            captured["kw"] = kw
            from backend.collectors.common.external import CollectResult

            return CollectResult()

    monkeypatch.setattr(external_cli, "PoliteClient", FakeClientCls)
    monkeypatch.delenv("GWITTIM_FIREBASE_PROJECT_ID", raising=False)
    for k, v in (env or {}).items():
        monkeypatch.setenv(k, v)
    external_cli.main(Mod, argv + ["--data-dir", str(tmp_path), "--dry-run"])
    return captured


def test_cli_batch_limits_default_to_5_pages_50_details_30_minutes(monkeypatch, tmp_path):
    cap = run_cli(monkeypatch, tmp_path, [])
    lim: RunLimits = cap["limits"]
    assert (lim.list_pages_per_site, lim.details_per_site, lim.seconds, lim.min_interval) == (5, 50, 1800, 3.0)
    assert cap["kw"]["pages"] == 5 and cap["kw"]["max_items"] == 50 and "backfill" not in cap["kw"]
    cap = run_cli(monkeypatch, tmp_path, ["--max-seconds", "420"])
    assert cap["limits"].seconds == 420


def test_cli_backfill_limits_are_time_and_requests_not_items(monkeypatch, tmp_path):
    cap = run_cli(monkeypatch, tmp_path, ["--backfill"])
    lim = cap["limits"]
    assert cap["kw"]["backfill"] is True
    assert lim.seconds == 3600 and lim.total_requests == 3000 and lim.min_interval == 3.0  # 간격은 줄이지 않음
    assert lim.details_per_site >= 10**6 and lim.list_pages_per_site >= BACKFILL_MAX_PAGES


def test_cli_backfill_refuses_firestore(monkeypatch, tmp_path):
    with pytest.raises(SystemExit):
        run_cli(monkeypatch, tmp_path, ["--backfill"], env={"GWITTIM_FIREBASE_PROJECT_ID": "x"})
