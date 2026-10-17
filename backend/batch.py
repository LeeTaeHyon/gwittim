"""수집 배치 한 번 실행: 수집 → 파이프라인 → 분석·검증 → 게시 → 사라진 공고 확인 (M1 경로, D-006).

팀장 PC에서 3시간마다 실행한다. 게시 대상(NoticeSink)은 Firestore 또는 메모리로 바꿔 끼운다.
"""
from __future__ import annotations

from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from datetime import date

from backend.analysis import build_notice
from backend.analysis.rules import Analyzer
from backend.collectors.common import Outcome, PipelineStore, ingest, record_probe
from backend.collectors.mjc_www.adapter import Board, collect, http_fetch, probe, view_url
from backend.publish import NoticeSink, PublishOutcome, publish

MAX_PROBES_PER_RUN = 20  # 사라진 공고 확인 요청 상한 (학교 서버 부담)


@dataclass
class BatchReport:
    collected: int = 0
    outcomes: dict[str, int] = field(default_factory=lambda: {o.value: 0 for o in Outcome})
    published: int = 0
    queued: int = 0
    skipped: int = 0
    probed: int = 0
    removed: int = 0
    fetch_errors: list[str] = field(default_factory=list)


def _publish(notice: dict, issues: list[str], sink: NoticeSink, report: BatchReport) -> None:
    outcome = publish(notice, issues, sink)
    if outcome is PublishOutcome.PUBLISHED:
        report.published += 1
    elif outcome is PublishOutcome.QUEUED:
        report.queued += 1
    else:
        report.skipped += 1


def run_batch(
    boards: Iterable[Board],
    *,
    store: PipelineStore,
    sink: NoticeSink,
    notices: dict[str, dict],
    today: date,
    pages: int = 2,
    max_items: int | None = None,
    analyzer: Analyzer | None = None,
    fetch: Callable[[str], str] = http_fetch,
    probe_fn: Callable[[str], str] = probe,
    delay: float = 1.0,
    max_probes: int = MAX_PROBES_PER_RUN,
) -> BatchReport:
    """notices: 키 → 마지막으로 만든 Notice (변경 필드 비교·분석 재사용용). 실행 후 갱신된다."""
    report = BatchReport()
    for board in boards:
        raws, errors = collect(board, pages=pages, max_items=max_items, fetch=fetch, delay=delay)
        report.fetch_errors += errors
        report.collected += len(raws)
        seen: set[str] = set()

        for raw in raws:
            result = ingest(raw, store)
            report.outcomes[result.outcome.value] += 1
            if result.outcome is Outcome.REJECTED or result.key is None:
                continue
            seen.add(result.key)
            record = store.get(result.key)
            if record.consecutive_not_found:  # 목록에 다시 보이면 삭제 확인 횟수 초기화
                record_probe(store, result.key, "found")
                record = store.get(result.key)
            notice, issues = build_notice(record, today=today, previous=notices.get(result.key), analyzer=analyzer)
            notices[result.key] = notice
            _publish(notice, issues, sink, report)

        # 이번에 본 목록 범위 안에 있어야 할 공고가 빠졌을 때만 원문 존재를 확인한다.
        # 범위 = 마지막 목록 행(고정 공지가 아닌 가장 오래된 글)의 게시일 이후. 오래돼서 밀려난 글은 확인하지 않는다.
        if not raws or not raws[-1]["source_fields"].get("posted_date"):
            continue
        window_start = raws[-1]["source_fields"]["posted_date"]
        missing = [
            k
            for k, n in notices.items()
            if k.startswith(board.source_id + ":")
            and k not in seen
            and n["lifecycle_status"] != "removed"
            and (n["published"] or {}).get("date", "") >= window_start
        ]
        for key in missing[:max_probes]:
            record = store.get(key)
            if record is None:
                continue
            raw = record.raw
            url = view_url(board, raw["source_fields"].get("bbs_mst_idx") or board.bbs_mst_idx, raw["source_notice_id"])
            report.probed += 1
            if record_probe(store, key, probe_fn(url)):
                report.removed += 1
                notice, issues = build_notice(store.get(key), today=today, previous=notices[key], analyzer=analyzer)
                notices[key] = notice
                _publish(notice, issues, sink, report)
    return report
