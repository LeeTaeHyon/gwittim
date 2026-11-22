"""tools/llm_board_read.py: 비교·전처리·api 호출·fake 흐름을 합성 값으로 확인한다 (네트워크·키 없음)."""
import io
import json
import urllib.error

import pytest

from tools import llm_board_read as t

GOLD = [
    {"title": "2026 장학금 안내", "posted_date": "2026-11-01", "data_idx": "BD0000000001", "bbs_mst_idx": "BM0000000026", "pinned": True},
    {"title": "근로학생 모집", "posted_date": "2026-11-02", "data_idx": "BD0000000002", "bbs_mst_idx": "BM0000000026", "pinned": False},
    {"title": "채용 설명회(온라인)", "posted_date": "2026-11-03", "data_idx": "BD0000000003", "bbs_mst_idx": "BM0000000026", "pinned": False},
]


def pred(g, **over):
    d = {"title": g["title"], "posted_date": g["posted_date"], "detail_url": f"fn_view('{g['bbs_mst_idx']}','{g['data_idx']}')",
         "is_pinned_notice": g["pinned"]}
    return {**d, **over}


def test_perfect():
    c = t.compare_page(GOLD, [pred(g) for g in GOLD])
    a = t.aggregate([c])
    assert (a["recall"], a["precision"], a["title_match"], a["date_match"], a["link_match"], a["pinned_match"]) == (1, 1, 1, 1, 1, 1)


def test_missed_and_false_positive():
    items = [pred(GOLD[0]), pred(GOLD[1]), {"title": "사이트맵", "posted_date": None, "detail_url": "/map", "is_pinned_notice": None}]
    c = t.compare_page(GOLD, items)
    a = t.aggregate([c])
    assert a["recall"] == pytest.approx(2 / 3, abs=1e-4)
    assert a["precision"] == pytest.approx(2 / 3, abs=1e-4)
    assert c["missed_titles"] == ["채용 설명회(온라인)"]
    assert c["false_titles"] == ["사이트맵"]


def test_title_match_without_id():
    items = [pred(g, detail_url=None, title=g["title"].replace(" ", "  ") + "!") for g in GOLD]
    c = t.compare_page(GOLD, items)
    assert c["matched"] == 3 and c["link_ok"] == 0 and c["title_ok"] == 3


def test_date_format_difference():
    items = [pred(GOLD[0], posted_date="2026.11.01"), pred(GOLD[1], posted_date="2026-11-09"), pred(GOLD[2], posted_date=None)]
    c = t.compare_page(GOLD, items)
    assert (c["date_ok"], c["date_n"]) == (1, 3)


def test_pinned_only_when_gold_has_it():
    gold = [{**GOLD[0], "pinned": None}, GOLD[1]]
    c = t.compare_page(gold, [pred(GOLD[0], is_pinned_notice=True), pred(GOLD[1], is_pinned_notice=True)])
    assert (c["pin_ok"], c["pin_n"]) == (0, 1)


def test_preprocess():
    html = "<html><!-- 주석 --><script>var x=1;</script><style>a{}</style><svg><path/></svg><p>  본문   글 </p></html>"
    text, cut = t.preprocess(html)
    assert "var x" not in text and "a{}" not in text and "path" not in text and "주석" not in text
    assert "본문 글" in text and not cut
    text, cut = t.preprocess("가" * 50, limit=10)
    assert len(text) == 10 and cut


class FakeResp:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return json.dumps(self.payload).encode("utf-8")


def test_api_request(monkeypatch):
    seen = {}

    def fake_urlopen(req, timeout=None):
        seen["req"], seen["timeout"] = req, timeout
        return FakeResp({"content": [{"type": "text", "text": '{"items": []}'}], "usage": {"input_tokens": 10, "output_tokens": 3}, "stop_reason": "end_turn"})

    monkeypatch.setattr(t.urllib.request, "urlopen", fake_urlopen)
    out = t.call_api("sys", "page", env={t.API_KEY_ENV: "sk-test-secret"})
    req = seen["req"]
    body = json.loads(req.data.decode("utf-8"))
    assert body["model"] == "claude-haiku-5-5" and body["max_tokens"] >= 16000
    assert body["output_config"]["effort"] == "low"
    assert body["output_config"]["format"]["type"] == "json_schema"
    headers = {k.lower(): v for k, v in req.header_items()}
    assert headers["x-api-key"] == "sk-test-secret" and headers["anthropic-version"] == "2023-06-01"
    assert out["input_tokens"] == 10 and out["output_tokens"] == 3


def test_api_retry_then_fail(monkeypatch):
    calls = []

    def fake_urlopen(req, timeout=None):
        calls.append(1)
        raise urllib.error.HTTPError("u", 429, "x", {}, io.BytesIO(b""))

    monkeypatch.setattr(t.urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(t.ToolError) as e:
        t.call_api("s", "u", env={t.API_KEY_ENV: "sk-test-secret"}, sleep=lambda s: None)
    assert len(calls) == 3 and "sk-test-secret" not in str(e.value)


def test_api_without_key_exits_with_notice(monkeypatch, capsys, tmp_path):
    monkeypatch.delenv(t.API_KEY_ENV, raising=False)
    monkeypatch.setattr(t, "PAGES_DIR", tmp_path)
    assert t.main(["run", "--provider", "api"]) == 2
    out = capsys.readouterr().out
    assert t.API_KEY_ENV in out


def test_fake_run_then_compare(monkeypatch, tmp_path, capsys):
    rows = "".join(
        f"<tr class=\"{'cell_notice' if i == 0 else ''}\"><td>{i}</td><td><a href=\"javascript:fn_view('BM0000000026','BD00000000{i:02d}')\">합성 제목 {i}번</a></td>"
        f"<td></td><td>학과</td><td>2026-11-{i + 1:02d}</td><td>3</td></tr>"
        for i in range(6)
    )
    pages = tmp_path / "pages"
    pages.mkdir()
    (pages / "mjc_www_notice_p1.html").write_text(f"<table><tbody>{rows}</tbody></table>", encoding="utf-8")
    monkeypatch.setattr(t, "PAGES_DIR", pages)
    monkeypatch.setattr(t, "RUNS_DIR", tmp_path / "runs")
    assert t.main(["run", "--provider", "fake"]) == 0
    out = capsys.readouterr().out
    run_dir = next((tmp_path / "runs").iterdir())
    summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
    o = summary["overall"]
    assert o["gold"] == 6 and o["matched"] == 4 and o["pred"] == 5  # 3번째마다 놓침 2개, 오탐 1개
    assert o["recall"] == pytest.approx(4 / 6, abs=1e-4) and o["link_match"] == 1
    assert summary["cost"]["total_krw"] is None and "재현율" in out
    assert "합성 제목" not in out.split("놓친 항목")[0]  # 요약 표 앞부분에 원문 나열 없음
