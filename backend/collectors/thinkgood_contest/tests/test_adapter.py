from pathlib import Path

from backend.collectors import thinkgood_contest
from backend.contracts import schema_errors

HTML = Path(__file__).parent / "html"


def read(name: str) -> str:
    return (HTML / name).read_text(encoding="utf-8")


class FakeClient:
    """POST 본문의 currentPageNo로 쪽을 고른다. 없는 쪽은 빈 목록."""

    def __init__(self, pages: dict[int, str]):
        self.pages, self.calls = pages, []

    def fetch(self, url, kind="detail", *, json_body=None):
        self.calls.append((url, kind, json_body))
        assert json_body is not None and url.endswith("/thinkgood/user/contest/subList.do")
        return self.pages.get(json_body["currentPageNo"], read("list_empty.json"))


PAGES = {1: read("list_p1.json"), 2: read("list_p2.json"), 3: read("list_p3.json")}


def test_parse_list():
    rows = thinkgood_contest.parse_list(read("list_p1.json"))
    assert [r.pk for r in rows] == ["900301", "900302", "900303", "900304"]
    assert [r.ended for r in rows] == [False, True, False, False]
    assert thinkgood_contest.parse_list("not json") == []
    assert thinkgood_contest.parse_list('{"status": "0"}') == []


def test_collect_uses_post_list_only_and_drops_contacts():
    client = FakeClient(PAGES)
    res = thinkgood_contest.collect(client, pages=1, collected_at="2026-11-26T03:00:00Z")
    assert [r["source_notice_id"] for r in res.raws] == ["900301", "900304"]  # 마감·청소년 전용 제외
    assert res.ended == 1 and list(res.excluded) == ["900303"]
    assert all(kind == "list" for _, kind, _ in client.calls) and len(client.calls) == 1  # 상세 요청 없음
    body = client.calls[0][2]
    assert body["currentPageNo"] == 1 and body["searchStatus"] == "Y"
    raw = res.raws[0]
    assert schema_errors("raw_notice", raw) == []
    assert raw["source_id"] == "thinkgood_contest" and raw["published"] is None
    assert raw["source_url"] == "https://www.thinkcontest.com/thinkgood/user/contest/view.do?contest_pk=900301"
    assert raw["title"] == "[합성 샘플] 대학생 아이디어 공모전"  # BOM 제거
    assert "접수기간: 2026-12-01 ~ 2026-12-31" in raw["body_text"] and "응모대상: 대학생, 대학원생, 일반인" in raw["body_text"]
    assert "sample@example.invalid" not in raw["body_text"] and "02-123-4567" not in raw["body_text"]
    assert "합성담당" not in str(raw)  # 담당자 정보는 읽지 않음
    assert raw["source_fields"]["official_url"] == "https://example.invalid/c/900301"


def test_backfill_walks_until_only_ended_page():
    client = FakeClient(PAGES)
    res = thinkgood_contest.collect(client, backfill=True)
    assert [r["source_notice_id"] for r in res.raws] == ["900301", "900304", "900305"]
    assert res.pages_read == 3 and res.stopped is None  # 3쪽은 마감만이라 거기서 끝
    assert [b["currentPageNo"] for _, _, b in client.calls] == [1, 2, 3]
