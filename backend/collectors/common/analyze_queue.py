"""교외 분석 단계 (한 번, 모든 출처). 대기열에서 꺼내 기존 _external_notice(build_notice → 검증 → 게시)로 처리한다.

uv run python -m backend.collectors.common.analyze_queue --data-dir data/local --max-seconds 1800

- 시간 상한(--max-seconds)에 닿으면 남은 건은 대기열에 두고 끝낸다. 건마다 시작 전에 확인하므로 마지막 한 건의 Ollama 응답
  대기(최대 120초)만큼 넘길 수 있다. 처리한 건은 대기열에서 빼므로 다음 실행에서 다시 분석하지 않는다.
- Ollama 실패는 OllamaAnalyzer가 규칙 분석으로 폴백하고 버전 접미사를 그대로 남긴다(기존 동작).
- 대기열 밖 기존 공고는 네트워크·LLM 없이 날짜만 다시 따진다(마감이 지나면 closed). 분석 버전이 같아 이전 분석을 재사용하는 경우만
  처리하고, 재분석이 필요한 건은 건드리지 않는다(재분석 금지). 단 분석 버전이 규칙 분석기 버전과 정확히 같은(= Gemma 실패 폴백) 게시 공고는
  실행당 20건까지 llm_fallback으로 대기열에 다시 넣는다(--no-llm이면 안 넣음). 아직 대기 중인 공고도 건드리지 않는다.
- Gemma 언로드는 끝에 한 번. 같은 data/local을 쓰므로 다른 배치와 동시에 돌리지 않는다. 결과는 한 줄 JSON.
"""
from __future__ import annotations

import argparse
import json
import os
import time
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from backend.analysis.external_match import EXTERNAL_PRIORITY
from backend.analysis.rules import Analyzer, RuleBasedAnalyzer
from backend.batch import BatchReport, _external_notice
from backend.publish import NoticeSink

from .analysis_queue import QUEUE_FILE, AnalysisQueue
from .store import JsonFileStore, PipelineStore

KST = timezone(timedelta(hours=9), "Asia/Seoul")
ANALYSIS_SECONDS = 30 * 60
# Gemma 실패로 규칙 분석만 남은 게시 공고를 다시 대기열에 넣는 실행당 상한. 한 번에 몰아 재분석하지 않게 하고(대량 재분석 금지),
# 공고당 분석이 약 10초라 20건이면 분석 단계에 약 3~4분만 더 든다. 넘는 건은 다음 배치로 미룬다.
REQUEUE_LLM_FALLBACK_MAX = 20
CHECKPOINT_EVERY = 10  # 이 건수마다 notices.json·대기열을 저장한다(중간에 죽어도 처리한 건이 되돌아가지 않게)


class NeedsAnalysis(Exception):
    """날짜 재판정 중 재분석이 필요해졌다는 신호. 이 경로에서는 분석하지 않는다."""


class _NoAnalysis:
    """build_notice가 이전 분석을 재사용할 때만 통과시키는 분석기. 분석이 필요하면 NeedsAnalysis."""

    def __init__(self, version: str) -> None:
        self.version = version

    def analyze(self, raw, source):
        raise NeedsAnalysis


def analyze_queue(
    queue: AnalysisQueue,
    *,
    store: PipelineStore,
    sink: NoticeSink,
    notices: dict[str, dict],
    today: date,
    analyzer: Analyzer | None,
    max_seconds: float,
    clock: Callable[[], float] = time.monotonic,
    save: Callable[[], None] = lambda: None,
) -> tuple[BatchReport, dict]:
    report = BatchReport()
    started = clock()
    processed = dropped = since_save = 0
    stopped: str | None = None
    llm0 = (getattr(analyzer, "llm_analyzed", 0), getattr(analyzer, "llm_failed", 0))
    done: set[str] = set()

    for entry in queue.ordered():
        if clock() - started >= max_seconds:
            stopped = f"분석 시간 상한 {round(max_seconds)}초"
            break
        key = entry["key"]
        if store.get(key) is None:
            queue.remove(key)  # 원문 기록이 없는 항목은 처리할 수 없다
            dropped += 1
            continue
        _external_notice(key, store, sink, notices, today, analyzer, report)
        queue.remove(key)
        done.add(key)
        processed += 1
        since_save += 1
        if since_save >= CHECKPOINT_EVERY:
            save()
            since_save = 0

    # 대기열 밖 기존 공고의 날짜 재판정 (네트워크·LLM 없음). 출처 우선순위 순서.
    guard = _NoAnalysis((analyzer or RuleBasedAnalyzer()).version)
    rejudged = rejudge_skipped = requeued = 0
    # LLM 실패 폴백 버전: 지금 규칙 분석기 버전과 정확히 같은 것만(+ollama가 붙은 것·다른 규칙 버전은 대상 아님). --no-llm이면 다시 넣지 않는다
    fallback_version = getattr(getattr(analyzer, "base", None), "version", None) if analyzer is not None else None
    for src in EXTERNAL_PRIORITY:
        prefix = src + ":"
        for key in [k for k in notices if k.startswith(prefix) and k not in done and k not in queue]:
            if store.get(key) is None:
                continue
            try:
                _external_notice(key, store, sink, notices, today, guard, report)
                rejudged += 1
            except NeedsAnalysis:
                rejudge_skipped += 1
                n = notices[key]
                if (fallback_version and requeued < REQUEUE_LLM_FALLBACK_MAX
                        and n.get("analysis_version") == fallback_version
                        and n.get("publication_status") == "published"
                        and n.get("lifecycle_status") not in ("closed", "removed")
                        and store.get(key).notice_version == n.get("notice_version")):
                    requeued += queue.add(src, key, "llm_fallback")
    save()

    stats = {
        "processed": processed,
        "dropped_no_record": dropped,
        "llm_analyzed": getattr(analyzer, "llm_analyzed", 0) - llm0[0],
        "fallback_rule_only": getattr(analyzer, "llm_failed", 0) - llm0[1],
        "rejudged": rejudged,
        "rejudge_skipped_needs_analysis": rejudge_skipped,
        "requeued_llm_fallback": requeued,
        "stopped": stopped,
    }
    return report, stats


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="backend.collectors.common.analyze_queue")
    ap.add_argument("--data-dir", type=Path, default=Path("data/local"))
    ap.add_argument("--max-seconds", type=float, default=ANALYSIS_SECONDS, help="분석 시간 상한(초). 기본 30분")
    ap.add_argument("--ollama-model", default="gemma4:12b", help="로컬 Ollama 보강 분석 모델 (D-007)")
    ap.add_argument("--no-llm", action="store_true", help="규칙 분석만 사용")
    args = ap.parse_args(argv)

    from backend.analysis.llm import OllamaAnalyzer
    from backend.publish import InMemorySink

    started = datetime.now(KST)
    store = JsonFileStore(args.data_dir / "pipeline")
    queue = AnalysisQueue(args.data_dir / QUEUE_FILE)
    before = len(queue)
    notices_path = args.data_dir / "notices.json"
    notices = json.loads(notices_path.read_text(encoding="utf-8")) if notices_path.exists() else {}

    project = os.environ.get("GWITTIM_FIREBASE_PROJECT_ID")
    if project:
        from backend.firebase_store import FirestoreSink, init_app

        sink = FirestoreSink(init_app(project))
    else:
        sink = InMemorySink()

    def save() -> None:
        tmp = notices_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(notices, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(notices_path)  # notices를 먼저 저장하고 대기열에서 뺀다
        queue.save()

    analyzer = None if args.no_llm else OllamaAnalyzer(args.ollama_model)
    report, stats = analyze_queue(
        queue, store=store, sink=sink, notices=notices, today=datetime.now(KST).date(),
        analyzer=analyzer, max_seconds=args.max_seconds, save=save,
    )
    used_llm = bool(analyzer and (analyzer.llm_analyzed or analyzer.llm_failed))
    unloaded = analyzer.unload() if used_llm else False
    finished = datetime.now(KST)
    summary = {
        "stage": "analyze_queue",
        "started_at": started.isoformat(timespec="seconds"),
        "finished_at": finished.isoformat(timespec="seconds"),
        "seconds": round((finished - started).total_seconds()),
        "llm": {"model": None if analyzer is None else analyzer.model, "used": used_llm, "unloaded": unloaded},
        "queue_before": before,
        "queue_load_error": queue.load_error,
        **stats,
        "published": report.published,
        "review_pending": report.queued,
        "duplicates": report.duplicates,
        "held_past": report.held_past,
        "remaining": len(queue),
        "oldest_wait_minutes": queue.oldest_wait_minutes(),
        "remaining_by_source": queue.remaining_by_source(),
    }
    summary["sink"] = f"firestore:{project}" if project else "local"
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
