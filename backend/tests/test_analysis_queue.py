"""교외 수집 단계와 분석 대기열 분리. 메모리 저장소·가짜 분석기만 쓴다."""
import json
from datetime import date, datetime, timezone

from backend.analysis.external_match import EXTERNAL_PRIORITY
from backend.analysis.rules import RuleBasedAnalyzer
from backend.batch import run_external
from backend.collectors.common import InMemoryStore
from backend.collectors.common.analysis_queue import AnalysisQueue, collect_to_queue
from backend.collectors.common.analyze_queue import analyze_queue
from backend.collectors.common.external import to_raw
from backend.publish import InMemorySink

AT = "2026-11-21T03:00:00Z"
TODAY = date(2026, 11, 21)
OPEN_BODY = "응모대상: 대학생\n접수기간: 2026-11-20 ~ 2026-12-18"


class CountingAnalyzer:
    """규칙 분석을 감싸 호출 수를 센다. 분석기 버전은 규칙 분석기와 같다."""

    def __init__(self, version=None):
        self.base = RuleBasedAnalyzer()
        self.version = version or self.base.version
        self.calls = []
        self.llm_analyzed = 0
        self.llm_failed = 0

    def analyze(self, raw, source):
        self.calls.append(raw["source_notice_id"])
        self.llm_analyzed += 1
        return self.base.analyze(raw, source)


def raw(source_id, nid, title, body=OPEN_BODY):
    return to_raw(source_id=source_id, notice_id=nid, url=f"https://example.invalid/{source_id}/{nid}", title=title,
                  body_text=body, source_fields={"audience": "대학생"}, collected_at=AT)


def dataset(version=0):
    body = OPEN_BODY + ("" if version == 0 else "\n추가 안내")
    dup = "[합성 샘플] 제30회 합성 축제 공식 포스터 디자인 공모전"
    return {
        "linkareer_contest": [raw("linkareer_contest", "l1", dup, body), raw("linkareer_contest", "l2", "[합성 샘플] 링커리어 단독 공모전", body)],
        "wevity_contest": [raw("wevity_contest", "w1", dup, body)],
        "allcon_contest": [
            raw("allcon_contest", "a1", "[합성 샘플] 이미 끝난 올콘 공고", "응모대상: 대학생\n접수기간: 2026-10-01 ~ 2026-10-31"),
            raw("allcon_contest", "a2", "[합성 샘플] 날짜가 거꾸로인 공고", "응모대상: 대학생\n접수기간: 2026-12-31 ~ 2026-12-01"),
        ],
        "linkareer_activity": [raw("linkareer_activity", "x1", "[합성 샘플] 대외활동 서포터즈", body)],
    }


def old_way(data_by_round):
    store, sink, notices = InMemoryStore(), InMemorySink(), {}
    totals = dict(published=0, queued=0, duplicates=0, held_past=0)
    for data in data_by_round:
        for src in EXTERNAL_PRIORITY:
            r = run_external(data.get(src, []), source_id=src, store=store, sink=sink, notices=notices, today=TODAY,
                             analyzer=CountingAnalyzer())
            for k in totals:
                totals[k] += getattr(r, k)
    return sink, notices, totals


def new_way(data_by_round, order=None, analyzer=None):
    store, sink, notices, queue = InMemoryStore(), InMemorySink(), {}, AnalysisQueue()
    analyzer = analyzer or CountingAnalyzer()
    totals = dict(published=0, queued=0, duplicates=0, held_past=0)
    for data in data_by_round:
        for src in order or list(reversed(EXTERNAL_PRIORITY)):  # 일부러 우선순위와 반대로 수집한다
            collect_to_queue(data.get(src, []), source_id=src, store=store, queue=queue, notices=notices)
        r, _ = analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=analyzer, max_seconds=1e9)
        for k in totals:
            totals[k] += getattr(r, k)
    return sink, notices, totals, analyzer


def test_collect_only_makes_no_analysis_and_queues_new_and_changed_only():
    store, notices, queue = InMemoryStore(), {}, AnalysisQueue()
    data = dataset()
    out = collect_to_queue(data["linkareer_contest"], source_id="linkareer_contest", store=store, queue=queue, notices=notices)
    assert out["outcomes"]["new"] == 2 and out["queued"] == 2 and len(queue) == 2 and notices == {}
    # 같은 내용: unchanged는 넣지 않는다 (이미 있는 항목도 그대로)
    out = collect_to_queue(data["linkareer_contest"], source_id="linkareer_contest", store=store, queue=queue, notices=notices)
    assert out["outcomes"]["unchanged"] == 2 and out["queued"] == 0 and len(queue) == 2
    first = {e["key"]: e["queued_at"] for e in queue.ordered()}
    # 바뀐 내용: changed지만 이미 대기 중이라 한 건으로 합치고 넣은 시각은 처음 값
    out = collect_to_queue(dataset(1)["linkareer_contest"], source_id="linkareer_contest", store=store, queue=queue, notices=notices)
    assert out["outcomes"]["changed"] == 2 and out["queued"] == 0 and len(queue) == 2
    assert {e["key"]: e["queued_at"] for e in queue.ordered()} == first


def test_unchanged_is_not_queued_after_analysis():
    store, sink, notices, queue = InMemoryStore(), InMemorySink(), {}, AnalysisQueue()
    data = dataset()
    collect_to_queue(data["wevity_contest"], source_id="wevity_contest", store=store, queue=queue, notices=notices)
    analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=CountingAnalyzer(), max_seconds=1e9)
    out = collect_to_queue(data["wevity_contest"], source_id="wevity_contest", store=store, queue=queue, notices=notices)
    assert out["outcomes"]["unchanged"] == 1 and out["queued"] == 0 and out["recovered"] == 0 and len(queue) == 0


def test_queue_order_follows_priority_then_oldest_first():
    q = AnalysisQueue()
    q.add("allcon_contest", "allcon_contest:1", "new", "2026-11-21T00:00:00Z")
    q.add("wevity_contest", "wevity_contest:2", "new", "2026-11-21T05:00:00Z")
    q.add("wevity_contest", "wevity_contest:1", "new", "2026-11-21T01:00:00Z")
    q.add("linkareer_contest", "linkareer_contest:1", "changed", "2026-11-20T00:00:00Z")
    assert [e["key"] for e in q.ordered()] == ["wevity_contest:1", "wevity_contest:2", "linkareer_contest:1", "allcon_contest:1"]
    assert q.remaining_by_source() == {"wevity_contest": 2, "linkareer_contest": 1, "allcon_contest": 1}


def test_same_final_result_as_current_way_including_cross_source_duplicate():
    rounds = [dataset(0), dataset(1)]  # 둘째 회차는 내용이 바뀐 공고
    sink_a, notices_a, totals_a = old_way(rounds)
    sink_b, notices_b, totals_b, _ = new_way(rounds)
    assert notices_a == notices_b
    assert sink_a.public == sink_b.public and sink_a.review == sink_b.review
    assert totals_a == totals_b
    # 시험 입력이 실제로 네 갈래를 모두 지난다
    assert totals_b["published"] > 0 and totals_b["queued"] > 0 and totals_b["duplicates"] > 0 and totals_b["held_past"] > 0


def test_time_limit_leaves_rest_and_resumes_without_reanalysis():
    data = dataset()
    store, sink, notices, queue = InMemoryStore(), InMemorySink(), {}, AnalysisQueue()
    for src, raws in data.items():
        collect_to_queue(raws, source_id=src, store=store, queue=queue, notices=notices)
    total = len(queue)
    analyzer = CountingAnalyzer()
    ticks = iter(range(0, 1000, 10))  # 호출마다 10초씩 흐르는 가짜 시계
    _, s1 = analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=analyzer,
                          max_seconds=25, clock=lambda: next(ticks))
    assert s1["processed"] == 2 and s1["stopped"] and len(queue) == total - 2
    done_first = list(analyzer.calls)
    assert len(analyzer.calls) == 2  # 처리 안 된 대기 공고는 날짜 재판정 중에도 분석되지 않는다
    _, s2 = analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=analyzer, max_seconds=1e9)
    assert s2["stopped"] is None and len(queue) == 0 and s2["processed"] == total - 2
    assert len(analyzer.calls) == total and len(set(analyzer.calls)) == total  # 한 건도 두 번 분석되지 않음
    assert not set(done_first) & set(analyzer.calls[2:])


def test_existing_notices_are_reused_without_analysis_and_date_rejudged():
    data = dataset()
    store, sink, notices, queue = InMemoryStore(), InMemorySink(), {}, AnalysisQueue()
    for src, raws in data.items():
        collect_to_queue(raws, source_id=src, store=store, queue=queue, notices=notices)
    analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=CountingAnalyzer(), max_seconds=1e9)
    # 같은 분석 버전: 마감(2026-12-18) 뒤에도 분석기 호출 0, closed로 바뀜
    again = CountingAnalyzer()
    _, stats = analyze_queue(queue, store=store, sink=sink, notices=notices, today=date(2027, 1, 5), analyzer=again, max_seconds=1e9)
    assert again.calls == [] and stats["processed"] == 0 and stats["rejudged"] > 0
    assert notices["wevity_contest:w1"]["lifecycle_status"] == "closed"
    # 분석 버전이 다르면 재분석하지 않고 건너뜀 (재분석 금지)
    other = CountingAnalyzer(version="other-version")
    before = json.dumps(notices, sort_keys=True)
    _, stats = analyze_queue(queue, store=store, sink=sink, notices=notices, today=date(2027, 2, 5), analyzer=other, max_seconds=1e9)
    assert other.calls == [] and stats["rejudge_skipped_needs_analysis"] > 0
    assert json.dumps(notices, sort_keys=True) == before


def test_queue_file_missing_or_broken_starts_empty(tmp_path):
    path = tmp_path / "analysis_queue.json"
    q = AnalysisQueue(path)
    assert len(q) == 0 and q.load_error is None
    q.add("wevity_contest", "wevity_contest:1", "new")
    q.save()
    assert len(AnalysisQueue(path)) == 1
    for bad in ("{깨진 json", '{"items": 3}', '{"items": [{"key": "k"}]}', "[]"):
        path.write_text(bad, encoding="utf-8")
        q2 = AnalysisQueue(path)
        assert len(q2) == 0 and q2.load_error is not None
        assert (tmp_path / "analysis_queue.json.broken").exists()
        q2.add("wevity_contest", "wevity_contest:1", "new")
        q2.save()  # 깨진 뒤에도 다시 쓸 수 있다


def test_records_without_notice_are_recovered_into_queue():
    # 대기열이 사라진 상황: 원문 기록은 있고 분석 결과·대기열은 없다
    data = dataset()
    store, notices = InMemoryStore(), {}
    collect_to_queue(data["linkareer_contest"], source_id="linkareer_contest", store=store, queue=AnalysisQueue(), notices=notices)
    queue = AnalysisQueue()
    out = collect_to_queue([], source_id="linkareer_contest", store=store, queue=queue, notices=notices)
    assert out["recovered"] == 2 and len(queue) == 2
    assert collect_to_queue([], source_id="wevity_contest", store=store, queue=queue, notices=notices)["recovered"] == 0


def test_oldest_wait_minutes():
    q = AnalysisQueue()
    q.add("wevity_contest", "wevity_contest:1", "new", "2026-11-21T00:00:00Z")
    assert q.oldest_wait_minutes(datetime(2026, 11, 21, 1, 30, tzinfo=timezone.utc)) == 90.0
    assert AnalysisQueue().oldest_wait_minutes() is None


# ---------- Gemma 실패 폴백 공고 다시 넣기 ----------


class LlmLikeAnalyzer(CountingAnalyzer):
    """OllamaAnalyzer처럼 version에 +ollama가 붙고 base를 가진다. fail이면 규칙 버전을 남긴다."""

    def __init__(self, fail=False):
        super().__init__()
        self.version = f"{self.base.version}+ollama:fake"
        self.fail = fail

    def analyze(self, raw, source):
        fields = super().analyze(raw, source)
        if self.fail:
            fields["_analysis_version"] = self.base.version
        return fields


def _seed(n, versions):
    """n건을 분석해 게시한 상태. versions는 처음 분석할 때 쓸 분석기."""
    store, sink, notices, queue = InMemoryStore(), InMemorySink(), {}, AnalysisQueue()
    raws = [raw("wevity_contest", f"s{i}", f"[합성 샘플] 서로 다른 공모전 {i}번 {'가나다라마바사아자차'[i % 10] * 5}") for i in range(n)]
    collect_to_queue(raws, source_id="wevity_contest", store=store, queue=queue, notices=notices)
    analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=versions, max_seconds=1e9)
    return store, sink, notices, queue


def test_only_fallback_version_is_requeued_and_then_not_again():
    store, sink, notices, queue = _seed(3, LlmLikeAnalyzer(fail=True))
    rule = RuleBasedAnalyzer().version
    assert all(n["analysis_version"] == rule for n in notices.values())
    keys = list(notices)
    notices[keys[1]]["analysis_version"] = rule + "+ollama:fake"  # Gemma로 분석된 공고
    notices[keys[2]]["analysis_version"] = "rule-0.1"  # 옛 규칙 버전
    good = LlmLikeAnalyzer()
    _, s = analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=good, max_seconds=1e9)
    assert s["requeued_llm_fallback"] == 1 and len(queue) == 1 and queue.ordered()[0]["reason"] == "llm_fallback"
    assert good.calls == []  # 다시 넣기만 하고 이 실행에서는 분석하지 않음
    _, s = analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=good, max_seconds=1e9)
    assert s["processed"] == 1 and s["requeued_llm_fallback"] == 0 and len(good.calls) == 1
    assert notices[keys[0]]["analysis_version"] == good.version and len(queue) == 0
    _, s = analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=good, max_seconds=1e9)
    assert s["requeued_llm_fallback"] == 0 and len(good.calls) == 1  # 다시 들어가지 않음


def test_requeue_cap_per_run(monkeypatch):
    from backend.collectors.common import analyze_queue as aq

    monkeypatch.setattr(aq, "REQUEUE_LLM_FALLBACK_MAX", 2)
    store, sink, notices, queue = _seed(5, LlmLikeAnalyzer(fail=True))
    _, s = analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=LlmLikeAnalyzer(), max_seconds=1e9)
    assert s["requeued_llm_fallback"] == 2 and len(queue) == 2


def test_no_llm_does_not_requeue():
    store, sink, notices, queue = _seed(2, LlmLikeAnalyzer(fail=True))
    for analyzer in (None, CountingAnalyzer()):  # --no-llm은 analyzer=None
        _, s = analyze_queue(queue, store=store, sink=sink, notices=notices, today=TODAY, analyzer=analyzer, max_seconds=1e9)
        assert s["requeued_llm_fallback"] == 0 and len(queue) == 0
