"""품질 평가 도구(tools/agent_eval_*.py) 시험. 합성 공고로 표본 규칙만 본다."""
from __future__ import annotations

from datetime import date

from tools.agent_eval_common import (
    GROUP_QUOTA, HOLDOUT_QUOTA, INFO_CATEGORIES, INFO_TOTAL, PASSED_MAX, profile, query_request, query_set, quote_in,
)
from tools.agent_eval_sample import draw

SOURCES = {"mjc_kakao": 60, "mjc_www_job": 30, "mjc_www_notice": 30, "wevity_contest": 40, "sewu_www_notice": 20}
CATS = ["contest", "job", "admin_notice", "event", "education_program", "other", "academic", "scholarship"]


def synthetic():
    notices, records = {}, {}
    i = 0
    for src, count in SOURCES.items():
        for j in range(count):
            i += 1
            key = f"{src}:{j:04}"
            cat = "contest" if src == "wevity_contest" else CATS[j % len(CATS)]
            notices[key] = {"source_id": src, "title": f"공고 {i}", "category": cat,
                            "application_deadline": {"date": "2026-11-01" if j % 3 == 0 else "2026-12-20"}}
            records[key] = {"raw": {"body_text": "본문 " * (10 + (j * 37) % 400)}}
    notices["mjc_kakao:9998"] = {"source_id": "mjc_kakao", "title": "합격자 발표", "category": "other"}
    records["mjc_kakao:9998"] = {"raw": {"body_text": "명단 " * 50}}
    notices["mjc_kakao:9999"] = {"source_id": "mjc_kakao", "title": "미리보기", "category": "job", "body_preview": True}
    records["mjc_kakao:9999"] = {"raw": {"body_text": "본문 " * 50}}
    return notices, records


def test_draw_quotas_and_limits():
    notices, records = synthetic()
    rows, meta = draw(notices, records, date(2026, 11, 24))
    assert len(rows) == sum(GROUP_QUOTA.values()) == 40
    for g, q in GROUP_QUOTA.items():
        part = [r for r in rows if r["group"] == g]
        assert len(part) == q
        assert sum(r["split"] == "holdout" for r in part) == HOLDOUT_QUOTA[g]
    assert sum(r["category"] in INFO_CATEGORIES for r in rows) == INFO_TOTAL
    assert sum(r["deadline_passed"] for r in rows) <= PASSED_MAX
    keys = {r["key"] for r in rows}
    assert "mjc_kakao:9998" not in keys and "mjc_kakao:9999" not in keys
    assert meta["dropped"] == {"명단형": 1, "폰 미리보기": 1}


def test_draw_is_reproducible():
    notices, records = synthetic()
    a, _ = draw(notices, records, date(2026, 11, 24))
    b, _ = draw(notices, records, date(2026, 11, 24))
    c, _ = draw(notices, records, date(2026, 11, 24), seed=1)
    assert a == b
    assert [r["key"] for r in a] != [r["key"] for r in c]


def test_queries_and_profiles():
    rows = query_set()
    assert len(rows) == 18 and sum(r["split"] == "dev" for r in rows) == 12
    assert sum(bool(r["query"]) for r in rows if r["split"] == "dev") == 4
    prof, body = query_request(rows[0])
    assert prof["interest_ids"] == [rows[0]["interest"]] and "experience" not in body
    p3, chips = profile("P3", "sewu")
    assert p3["university_id"] == "sewu" and p3["enrollment_status"] == "on_leave" and chips == {}


def test_eval_dates_uses_published_day_and_visibility():
    from tools.agent_eval_prep import eval_dates

    notices = {
        "a": {"published": {"date": "2025-11-01"}, "lifecycle_status": "closed",
              "application_deadline": {"date": "2025-11-10"}},
        "b": {"published": {"date": "2026-08-01"}, "lifecycle_status": "unknown", "application_deadline": None},
        "c": {"published": None, "lifecycle_status": "open", "application_deadline": {"date": "2026-11-20"}},
        "d": {"published": {"date": "2026-11-20"}, "lifecycle_status": "open",
              "application_deadline": {"date": "2026-11-10"}},
    }
    rows = [{"key": k, "split": "dev", "group": "g"} for k in notices]
    out = eval_dates(rows, notices, date(2026, 11, 24))
    by = {r["key"]: r for r in out["rows"]}
    assert by["a"]["eval_today"] == "2025-11-01" and not by["a"]["visible"]
    assert by["b"]["stale"] and not by["b"]["visible"]  # 마감 미상, 게시 후 60일 초과
    assert by["c"]["eval_today"] == "2026-11-24" and by["c"]["today_from"] == "measure_day"
    assert out["counts"] == {"visible": 2, "visible_by_group": {"g": 2}, "closed": 1, "stale": 1}
    assert out["deadline_passed_at_eval_today"] == {"count": 2, "keys": ["c", "d"]}


def test_pick_human_is_fixed_and_inside_dev():
    from tools.agent_eval_prep import pick_human

    dev = [f"k{i:02}" for i in range(30)]
    a, b = pick_human(dev), pick_human(list(reversed(dev)))
    assert a == b and len(a) == 10 and set(a) <= set(dev)


def test_external_plan_and_peak():
    from datetime import datetime

    from tools.agent_eval_external import KST, html_text, is_peak, plan

    runs = plan(query_set())
    assert len(runs) == 20 and sum(r["rep"] == 1 for r in runs) == 12
    assert {r["qid"] for r in runs if r["rep"] > 1} == {"Q01", "Q04", "Q07", "Q10"}
    assert is_peak(datetime(2026, 11, 24, 10, 30, tzinfo=KST)) and not is_peak(datetime(2026, 11, 24, 9, 59, tzinfo=KST))
    assert not is_peak(datetime(2026, 11, 28, 11, 0, tzinfo=KST))  # 토요일
    assert html_text("<p>접수&nbsp;마감</p><script>x()</script><b>12.5</b>") == "접수\xa0마감\n12.5"


def test_detail_jobs_hash_changes_with_input():
    from tools.agent_eval_detail import input_hash

    assert input_hash("s", "u") == input_hash("s", "u") != input_hash("s", "u2")


def test_quote_in_ignores_spacing_and_symbols():
    assert quote_in("접수 마감: 12.5(금)", "...접수마감 12.5 (금) 까지")
    assert not quote_in("", "본문")
    assert not quote_in("없는 문장", "본문")


# ---------- 2차 (§16) ----------

def test_redirect_and_open_state():
    from tools.agent_eval_external import open_state, redirected_home

    assert redirected_home("https://linkareer.com/activity/364244", "https://linkareer.com/")
    assert not redirected_home("https://linkareer.com/activity/1", "https://linkareer.com/activity/1")
    assert not redirected_home("https://a.kr/", "https://a.kr/")
    assert not redirected_home("https://a.kr/view", None)
    assert [open_state(s) for s in ("ok", "login", "robots", "http_404", "error", "redirected", None)] == [
        "opened", "unverifiable", "unverifiable", "broken", "broken", "broken", "not_fetched"]


def test_d2_verify_quotes_drops_unquoted_lines():
    from tools.agent_eval_variants import verify_quotes

    body = "접수 기간 : 11.18(수) ~ 12.08(화) 23:59\n참가 형태 : 개인 또는 팀(최대 3인)"
    raw = {
        "fit": [{"text": "맞음: 팀으로 참여할 수 있습니다", "basis": "본문", "quote": "참가 형태 : 개인 또는 팀(최대 3인)"}],
        "eligibility": [{"text": "확인 필요: 학년 조건 미상", "basis": "판정"}],
        "todo": [{"text": "마감 전 제출합니다", "basis": "본문", "quote": "12월 10일 마감"}],
        "skills": [{"text": "영상 편집", "basis": "본문", "quote": None}],
    }
    report, stats = verify_quotes(raw, body)
    assert report["fit"] == "맞음: 팀으로 참여할 수 있습니다" and report["eligibility"] == "확인 필요: 학년 조건 미상"
    assert report["todo"] == "" and report["skills"] == ""
    assert stats["lines"] == 4 and stats["dropped"] == 2 and stats["emptied_fields"] == ["todo", "skills"]


def test_d1_skills_grounded_on_body_keeps_preferred_mark():
    from datetime import date

    from backend.agent.prompt import ground_report
    from tools.agent_eval_variants import notice_with_body

    notice = {"eligibility": {"unresolved_conditions": [{"evidence": "파이썬 사용 경험자 우대", "note": "우대 사항"}]},
              "application_deadline": {"date": "2026-12-31"}}
    record = {"raw": {"body_text": "출품 규격 : 20~40초 세로형 영상\n영상 편집 프로그램 사용 가능자"}}
    report = {"fit": "맞음: x", "eligibility": "충족: x", "todo": "x합니다.", "skills": "영상 편집 프로그램 사용\n파이썬 사용 경험\n리더십"}
    out, _ = ground_report(report, notice_with_body(notice, record), "met", date(2026, 11, 24))
    assert out["skills"].split("\n") == ["영상 편집 프로그램 사용", "파이썬 사용 경험 (우대)"]


def test_absent_wrong_only_counts_contradicted_absence_lines():
    from tools.agent_eval_score import absent_wrong

    c = {"field": "fit", "text": "확인 필요: 행사 종료일이 제시되지 않아 확인해야 합니다."}
    assert absent_wrong(c, {"label": "contradicts"}) and not absent_wrong(c, {"label": "grounded"})
    assert not absent_wrong({"field": "eligibility", "text": "확인 필요: 학년이 명시되지 않음"}, {"label": "contradicts"})


# ---------- 3차 (§17) ----------

def test_d3_d4_prompts_change_only_intended_lines():
    import difflib

    from tools.agent_eval_variants import SYSTEM

    def changed(a: str, b: str) -> list[str]:
        return [ln[2:] for ln in difflib.ndiff(SYSTEM[a].split("\n"), SYSTEM[b].split("\n")) if ln.startswith("+ ")]

    d3 = changed("D1", "D3")
    assert len(d3) == 4 and "- 쓸 내용이 없으면 줄을 줄입니다." in d3
    assert any('"fit"(최대 4줄)' in ln for ln in d3) and any('"todo"(1~4줄)' in ln for ln in d3)
    assert any("최대 4개만 씁니다. 5줄 이상 쓰지 않습니다." in ln for ln in d3)
    d4 = changed("D3", "D4")
    assert len(d4) == 1 and "'원문에서 확인할 조건' 원문 또는 공고 본문입니다" in d4[0]
