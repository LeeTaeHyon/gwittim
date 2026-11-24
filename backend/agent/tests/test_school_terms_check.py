"""tools/school_terms_check.py: robots 파싱·약관 링크·인용 확인·보고서 문구·요청 상한을 합성 값으로 확인한다 (네트워크·LLM 없음)."""
import io
import json
import urllib.error

from backend.collectors.common.http_polite import PoliteClient, RunLimits
from tools import school_terms_check as t

ROBOTS = """User-agent: *
Disallow: /_attach/
Disallow: /admin/ # 관리자

User-agent: GwittimBot
Disallow: /private/
"""
BLOCK_ALL = "User-agent: *\nDisallow: /\n"
MAIN = """<html><body><a href="/">홈</a>
<a href="/privacy.do">개인정보처리방침</a><a href="/terms.do">이용약관</a>
<a href="javascript:openTerms()">저작권 정책</a><a href="https://other.example/terms">이용약관</a></body></html>"""
TERMS = """<html><head><title>x</title><script>var a=1;</script></head><body>
<p>제1조 이용자는 로봇 등 자동화된 수단으로 정보를 수집하여서는 아니 된다.</p>
<p>제2조 회원은 게시물을 무단으로 복제할 수 없다.</p></body></html>"""


class Resp(io.BytesIO):
    headers = {"Content-Type": "text/html; charset=utf-8"}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def make_client(pages: dict, limit=10):
    calls = []

    def opener(req, timeout=None):
        calls.append(req.full_url)
        body = pages.get(req.full_url)
        if body is None:
            raise urllib.error.HTTPError(req.full_url, 404, "nf", {}, None)
        return Resp(body.encode())

    c = PoliteClient(limits=RunLimits(total_requests=limit), opener=opener, sleep=lambda s: None)
    return c, calls


def test_parse_robots():
    p = t.parse_robots(ROBOTS)["agents"]
    assert p["*"]["disallow"] == ["/_attach/", "/admin/"]
    assert p["gwittimbot"]["disallow"] == ["/private/"]


def test_robots_summary_boards_and_site():
    s = t.robots_summary(ROBOTS, "https://x.ac.kr", ["/private/list", "/bbs/"])
    assert s["site_blocked"] is False
    assert s["boards"] == {"/private/list": True, "/bbs/": False}
    assert t.robots_summary(BLOCK_ALL, "https://x.ac.kr", ["/bbs/"])["site_blocked"] is True
    assert t.robots_summary(None, "https://x.ac.kr", [])["read"] is False


def test_find_links_same_site_only():
    f = t.find_links(MAIN, "https://x.ac.kr/")
    assert [x["url"] for x in f["terms"]] == ["https://x.ac.kr/terms.do", None, None]
    assert f["privacy"][0]["url"] == "https://x.ac.kr/privacy.do"


def test_verify_clauses_drops_invented():
    text = t.html_to_text(TERMS)
    assert "var a" not in text
    kept, dropped = t.verify_clauses([
        {"quote": "제1조 이용자는 로봇 등 자동화된 수단으로 정보를 수집하여서는 아니 된다.", "category": "auto_all"},
        {"quote": "이 문장은 원문에 없다", "category": "auto_all"},
        {"quote": "제2조 회원은 게시물을 무단으로 복제할 수 없다.", "category": "엉뚱"},
    ], text)
    assert len(kept) == 1 and kept[0]["category"] == "auto_all"
    assert [d["reason"] for d in dropped] == ["원문에 없음", "분류 값 오류"]


def llm_fake(text):
    return json.dumps({"clauses": [
        {"quote": "제1조 이용자는 로봇 등 자동화된 수단으로 정보를 수집하여서는 아니 된다.", "category": "auto_all"},
        {"quote": "지어낸 문장", "category": "commercial"},
    ]}, ensure_ascii=False)


def test_check_school_end_to_end_and_report(tmp_path):
    base = "https://www.mjc.ac.kr"
    client, calls = make_client({base + "/robots.txt": ROBOTS, base + t.SCHOOLS["mjc"]["home"]: MAIN, base + "/terms.do": TERMS})
    res = t.check_school("mjc", client, llm_fake)
    assert calls.count(base + "/robots.txt") == 1  # robots를 두 번 읽지 않음
    assert res["requests"] == len(calls) <= t.MAX_REQUESTS
    assert len(res["clauses"]) == 1 and len(res["dropped"]) == 1
    md = t.render_md(res)
    assert "판단은 팀장" in md and "제1조 이용자는 로봇" in md
    for bad in ("지원 가능", "지원 불가", "지원할 수", "수집 가능", "수집 불가"):
        assert bad not in md


def test_no_terms_page_and_privacy_not_terms():
    base = "https://www.sewu.ac.kr"
    html = '<a href="/p.do">개인정보처리방침</a>'
    client, calls = make_client({base + "/robots.txt": ROBOTS, base + t.SCHOOLS["sewu"]["home"]: html})
    res = t.check_school("sewu", client, llm_fake)
    assert res["llm"] == "약관 본문 없음" and res["links"]["terms"] == []
    assert base + "/p.do" not in calls
    assert "약관 페이지 없음" in t.render_md(res)


def test_site_blocked_makes_no_page_request():
    base = "https://www.baewha.ac.kr"
    client, calls = make_client({base + "/robots.txt": BLOCK_ALL, base + t.SCHOOLS["mjc"]["home"]: MAIN})
    res = t.check_school("baewha", client, llm_fake)
    assert calls == [base + "/robots.txt"]
    assert res["robots"]["site_blocked"] is True


def test_request_limit_enforced():
    base = "https://www.mjc.ac.kr"
    client, calls = make_client({base + "/robots.txt": ROBOTS, base + t.SCHOOLS["mjc"]["home"]: MAIN, base + "/terms.do": TERMS}, limit=2)
    res = t.check_school("mjc", client, llm_fake)
    assert len(calls) == 2
    assert any("요청 중단" in n for n in res["notes"])


def test_llm_failure_is_recorded():
    base = "https://www.mjc.ac.kr"
    client, _ = make_client({base + "/robots.txt": ROBOTS, base + t.SCHOOLS["mjc"]["home"]: MAIN, base + "/terms.do": TERMS})

    def boom(text):
        raise RuntimeError("x")

    res = t.check_school("mjc", client, boom)
    assert res["llm"].startswith("실패") and res["clauses"] == []


def test_run_one_writes_file_only(tmp_path):
    base = "https://www.mjc.ac.kr"
    client, _ = make_client({base + "/robots.txt": ROBOTS, base + t.SCHOOLS["mjc"]["home"]: MAIN, base + "/terms.do": TERMS})
    t.run_one("mjc", llm_fake, out_dir=tmp_path, client_factory=lambda: client)
    assert [p.name for p in tmp_path.iterdir()] == ["mjc.md"]


def test_schools_table_fixed():
    assert set(t.SCHOOLS) == {"mjc", "sewu", "baewha"}
