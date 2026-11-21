"""교외 출처(D-038)의 수집 → 분석 → 게시 흐름. 가짜 HTTP·메모리 저장소만 쓴다."""
from datetime import date
from pathlib import Path

from backend.batch import run_external
from backend.collectors import wevity
from backend.collectors.common import InMemoryStore
from backend.collectors.common.external import to_raw
from backend.contracts import schema_errors
from backend.publish import InMemorySink

HTML = Path(wevity.__file__).parent / "tests" / "html"
PAGES = {
    "gp=1": (HTML / "list.html").read_text(encoding="utf-8"),
    "ix=900001": (HTML / "view.html").read_text(encoding="utf-8"),
    "ix=900002": (HTML / "view_minor.html").read_text(encoding="utf-8"),
    "ix=900003": (HTML / "view_noaudience.html").read_text(encoding="utf-8"),
}
AT = "2026-11-21T03:00:00Z"
TODAY = date(2026, 11, 21)


class FakeClient:
    def fetch(self, url, kind="detail"):
        return next(html for key, html in PAGES.items() if key in url)


def run(store, sink, notices, today=TODAY, raws=None):
    if raws is None:
        raws = wevity.collect(FakeClient(), pages=1, collected_at=AT).raws
    return run_external(raws, source_id=wevity.SOURCE_ID, store=store, sink=sink, notices=notices, today=today)


def test_external_notices_flow_to_public():
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    report = run(store, sink, notices)
    assert report.collected == 2 and report.published == 2 and report.queued == 0
    assert len(sink.public) == 2
    for n in sink.public.values():
        assert schema_errors("notice", n) == []
        assert n["source_id"] == "wevity_contest" and n["source_url"].startswith("https://www.wevity.com/")
        assert n["publication_status"] == "published"
    # 같은 내용을 다시 받으면 새 버전·재게시 없이 건너뜀
    again = run(store, sink, notices)
    assert again.published == 0 and again.skipped == 2 and again.outcomes["unchanged"] == 2


def test_validation_failure_goes_to_review_pending():
    raw = to_raw(
        source_id=wevity.SOURCE_ID,
        notice_id="900050",
        url="https://www.wevity.com/?c=find&gbn=viewok&ix=900050",
        title="[합성 샘플] 날짜 순서가 거꾸로인 공고",
        body_text="응모대상: 대학생\n접수기간: 2026-12-31 ~ 2026-12-01",
        source_fields={"audience": "대학생"},
        collected_at=AT,
    )
    store, sink = InMemoryStore(), InMemorySink()
    report = run(store, sink, {}, raws=[raw])
    assert report.queued == 1 and report.published == 0
    assert not sink.public and len(sink.review) == 1
    assert sink.review[next(iter(sink.review))]["notice"]["publication_status"] == "review_pending"


def test_already_closed_notice_is_not_published():
    raw = to_raw(
        source_id=wevity.SOURCE_ID,
        notice_id="900060",
        url="https://www.wevity.com/?c=find&gbn=viewok&ix=900060",
        title="[합성 샘플] 이미 끝난 공고",
        body_text="응모대상: 대학생\n접수기간: 2026-10-01 ~ 2026-10-31",
        source_fields={"audience": "대학생"},
        collected_at=AT,
    )
    store, sink = InMemoryStore(), InMemorySink()
    report = run(store, sink, {}, raws=[raw])
    assert report.held_past == 1 and not sink.public and not sink.review


def test_published_notice_turns_closed_after_deadline_without_new_raw():
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    run(store, sink, notices)
    key = "wevity_contest:900001"
    assert notices[key]["lifecycle_status"] == "open"
    # 마감(2026-12-31) 뒤: 목록에서 안 보여 raw가 없어도 날짜만 다시 따져 closed로 게시
    report = run(store, sink, notices, today=date(2027, 1, 5), raws=[])
    assert notices[key]["lifecycle_status"] == "closed"
    assert sink.public[notices[key]["notice_id"]]["lifecycle_status"] == "closed"
    assert report.collected == 0 and report.published >= 1
