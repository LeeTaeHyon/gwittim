from datetime import date

from backend.recommendation.similar import similar_notices, similarity_score, title_keywords

TODAY = date(2026, 11, 19)


def n(
    nid, category="contest", title="", tags=(), roles=(), deadline="2026-12-01",
    lifecycle="open", publication="published", published="2026-11-10",
):
    return {
        "notice_id": nid,
        "category": category,
        "title": title,
        "interest_tags": list(tags),
        "related_roles": list(roles),
        "application_deadline": None if deadline is None else {"date": deadline},
        "lifecycle_status": lifecycle,
        "publication_status": publication,
        "published": None if published is None else {"date": published},
    }


TARGET = n("t", category="contest", title="AI 해커톤 참가자 모집", tags=["ai_data", "software"])


def ids(result):
    return [x["notice_id"] for x in result]


def test_excludes_self():
    assert ids(similar_notices(TARGET, [dict(TARGET), n("a")], TODAY)) == ["a"]


def test_excludes_past_deadline_keeps_today():
    got = similar_notices(TARGET, [n("old", deadline="2026-11-18"), n("today", deadline="2026-11-19")], TODAY)
    assert ids(got) == ["today"]


def test_deadline_none_included():
    assert ids(similar_notices(TARGET, [n("u", deadline=None, lifecycle="unknown")], TODAY)) == ["u"]


def test_more_shared_tags_ranks_higher():
    c1 = n("one", category="other", tags=["ai_data"])
    c2 = n("two", category="other", tags=["ai_data", "software"])
    assert ids(similar_notices(TARGET, [c1, c2], TODAY)) == ["two", "one"]


def test_category_beats_keyword():
    same_cat = n("cat", category="contest", title="무관한 제목")
    kw = n("kw", category="other", title="해커톤 AI 대회")
    assert ids(similar_notices(TARGET, [kw, same_cat], TODAY)) == ["cat", "kw"]


def test_zero_score_excluded():
    assert similar_notices(TARGET, [n("z", category="other", title="식당 휴무")], TODAY) == []


def test_max_three_default_and_limit():
    cands = [n(f"c{i}") for i in range(6)]
    assert len(similar_notices(TARGET, cands, TODAY)) == 3
    assert len(similar_notices(TARGET, cands, TODAY, limit=5)) == 5


def test_tie_order_deterministic():
    cands = [
        n("b", deadline="2026-12-10"),
        n("a", deadline="2026-12-10"),
        n("far", deadline="2026-12-30"),
        n("near", deadline="2026-11-25"),
        n("unk", deadline=None),
    ]
    want = ["near", "a", "b", "far", "unk"]
    assert ids(similar_notices(TARGET, cands, TODAY, limit=10)) == want
    assert ids(similar_notices(TARGET, list(reversed(cands)), TODAY, limit=10)) == want


def test_stopwords_only_overlap_is_zero():
    a = n("a", category="x", title="2026 모집 안내 공고 신청")
    b = n("b", category="y", title="[공고] 2026 신청 안내, 모집")
    assert title_keywords(a["title"]) == set()
    assert similarity_score(a, b) == 0


def test_missing_fields_treated_empty():
    assert similar_notices({"notice_id": "t"}, [{"notice_id": "x"}], TODAY) == []
    # 상태 칸이 없으면 게시 여부를 알 수 없어 점수가 있어도 뺀다
    bare = {k: v for k, v in n("bare").items() if k not in ("lifecycle_status", "publication_status")}
    assert similar_notices(TARGET, [bare, n("ok")], TODAY) == [n("ok")]


def test_excludes_closed_and_removed_even_without_deadline():
    # 선착순 마감처럼 마감일 없이 끝난 공고
    cands = [n("closed", deadline=None, lifecycle="closed"), n("removed", lifecycle="removed"), n("ok")]
    assert ids(similar_notices(TARGET, cands, TODAY)) == ["ok"]


def test_excludes_review_pending():
    cands = [n("pending", publication="review_pending"), n("ok")]
    assert ids(similar_notices(TARGET, cands, TODAY)) == ["ok"]


def test_excludes_admin_notice():
    target = n("t2", category="admin_notice", title="등록금 납부 안내")
    cands = [n("admin", category="admin_notice", title="등록금 납부 안내"), n("ok", title="등록금 장학 안내")]
    assert ids(similar_notices(target, cands, TODAY)) == ["ok"]


def test_excludes_stale_unknown_deadline():
    # 마감 미상인 채 게시 후 60일이 지나면 기본 추천처럼 뺀다(D-013). 60일째는 남는다
    stale = n("stale", deadline=None, lifecycle="unknown", published="2026-09-19")  # 61일
    edge = n("edge", deadline=None, lifecycle="unknown", published="2026-09-20")  # 60일
    no_pub = n("nopub", deadline=None, lifecycle="unknown", published=None)  # 게시일 미상은 판단 안 함
    assert ids(similar_notices(TARGET, [stale, edge, no_pub], TODAY)) == ["edge", "nopub"]
