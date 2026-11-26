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


# ---------- 교외 출처끼리 같은 공고 (D-048) ----------

from backend.analysis.external_match import find_preferred_same, same_notice  # noqa: E402
from backend.collectors import contestkorea  # noqa: E402


def _raw(source_id, nid, title, body):
    return to_raw(source_id=source_id, notice_id=nid, url=f"https://example.invalid/{source_id}/{nid}", title=title,
                  body_text=body, source_fields={"audience": "대학생"}, collected_at=AT)


def _n(title, deadline, source="contestkorea_contest", status="open"):
    return {"title": title, "source_id": source, "lifecycle_status": status,
            "application_deadline": {"date": deadline} if deadline else None}


def test_same_notice_rule():
    a = _n("제30회 보령머드축제 공식 포스터 디자인 공모전", "2026-12-18", "wevity_contest")
    assert same_notice(a, _n("[공모전] 제30회 보령머드축제 공식 포스터 디자인 공모전", "2026-12-18"))
    assert same_notice(_n("2027 광석이 다시 만나기 경연 예선 모집 공고", "2026-12-14", "wevity_contest"),
                       _n("2027 광석이 다시 만나기 경연", "2026-12-14"))  # 한쪽 제목이 통째로 들어감
    assert not same_notice(a, _n("제30회 보령머드축제 공식 포스터 디자인 공모전", "2026-12-20"))  # 마감이 다름
    assert not same_notice(_n("제3회 합성 AI 광고 공모전", "2026-11-30", "wevity_contest"),
                           _n("제3회 합성 AI 영상 공모전", "2026-11-30"))
    # 마감을 모르면 더 엄격하게
    assert same_notice(_n("합성 대학생 서포터즈 3기 모집", None, "wevity_contest"), _n("합성 대학생 서포터즈 3기 모집", None))
    assert not same_notice(_n("합성 대학생 서포터즈 3기 모집", None, "wevity_contest"), _n("합성 대학생 서포터즈 4기", None))


def test_preferred_source_wins_regardless_of_order():
    w = _n("제30회 보령머드축제 공식 포스터 디자인 공모전", "2026-12-18", "wevity_contest")
    c = _n("제30회 보령머드축제 공식 포스터 디자인 공모전", "2026-12-18")
    notices = {"wevity_contest:1": w, "contestkorea_contest:9": c}
    assert find_preferred_same(c, notices) == "wevity_contest:1"
    assert find_preferred_same(w, notices) is None  # 위비티는 남는다
    assert find_preferred_same(c, {"wevity_contest:1": {**w, "lifecycle_status": "closed"}}) is None  # 끝난 공고와는 짝 안 함
    assert find_preferred_same({**c, "source_id": "mjc_www_notice"}, notices) is None  # 학교 공지는 대상 아님


def test_batch_skips_and_unpublishes_duplicate_from_later_source():
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    body = "응모대상: 대학생\n접수기간: 2026-11-20 ~ 2026-12-18"
    title = "[합성 샘플] 제30회 합성 축제 공식 포스터 디자인 공모전"
    # 콘테스트코리아가 먼저 게시돼 있던 상황(이 규칙 전 배치)
    run_external([_raw(contestkorea.SOURCE_ID, "c1", title, body)], source_id=contestkorea.SOURCE_ID, store=store,
                 sink=sink, notices=notices, today=TODAY)
    assert len(sink.public) == 1
    run_external([_raw(wevity.SOURCE_ID, "w1", title, body)], source_id=wevity.SOURCE_ID, store=store, sink=sink,
                 notices=notices, today=TODAY)
    report = run_external([], source_id=contestkorea.SOURCE_ID, store=store, sink=sink, notices=notices, today=TODAY)
    assert report.duplicates == 1
    assert [n["source_id"] for n in sink.public.values()] == ["wevity_contest"]


def test_same_notice_across_menus_and_sources_keeps_higher_priority():
    """D-059: 위비티 > 콘테스트코리아 > 링커리어, 같은 출처는 공모전 메뉴가 대외활동 메뉴보다 앞."""
    from backend.analysis.external_match import find_preferred_same

    def n(source, title="[합성 샘플] 전국 대학생 영상 공모전", status="active"):
        return {"source_id": source, "title": title, "application_deadline": {"date": "2026-12-31"}, "lifecycle_status": status}

    ids = ("wevity_contest", "wevity_activity", "contestkorea_contest", "linkareer_contest", "linkareer_activity")
    notices = {k: n(k) for k in ids}
    assert find_preferred_same(notices["wevity_contest"], notices) is None
    assert find_preferred_same(notices["wevity_activity"], notices) == "wevity_contest"
    assert find_preferred_same(notices["contestkorea_contest"], notices) == "wevity_contest"
    assert find_preferred_same(notices["linkareer_contest"], notices) is not None
    lk = {k: v for k, v in notices.items() if k.startswith("linkareer")}
    assert find_preferred_same(lk["linkareer_activity"], lk) == "linkareer_contest"
    assert find_preferred_same(lk["linkareer_contest"], lk) is None
    closed = {"wevity_contest": n("wevity_contest", status="closed"), "linkareer_contest": n("linkareer_contest")}
    assert find_preferred_same(closed["linkareer_contest"], closed) is None  # 끝난 공고와는 짝짓지 않음
    other = {"wevity_contest": n("wevity_contest", title="전혀 다른 제목의 공고입니다 안내"), "x": n("linkareer_contest")}
    assert find_preferred_same(other["x"], other) is None
