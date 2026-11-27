"""교외 출처 배치 실행의 공통 진입점 (D-038). 출처별 `__main__`이 자기 어댑터 모듈을 넘겨 부른다.

수집 → 파이프라인 → 분석·검증 → 게시. mjc_www 배치와 같은 data/local 기록(pipeline/, notices.json)을 쓰므로
다른 배치와 동시에 돌리지 않는다. 대학생 대상이 아니라 걸러 낸 공고는 external_excluded.json에,
429·403 멈춤은 external_site_stops.json에 남는다.

--dry-run: 실제 사이트에 요청하되 저장·분석·게시 없이 건수만 출력한다.

정기 배치 상한(D-059): 목록 5페이지, 새 공고 상세 50건, 실행 시간은 --max-seconds(배치 스크립트가 남은 시간을 넘김).
--collect-only: 수집 단계만. 저장(new/changed/unchanged 판정)하고 new·changed를 분석 대기열(analysis_queue.json)에 넣고 끝낸다.
분석·게시는 analyze_queue가 모든 출처를 한 번에 한다. 상한은 같다(--max-seconds 기본 20분).
--backfill: 수동 1회성 채우기(D-059). 목록을 끝까지 넘기며 접수 중인 공고를 모두 모은다. 상세 건수 상한 없이 실행 시간(기본 60분)·
HTTP 요청(기본 3000건) 상한만 둔다. Firestore에는 반영하지 않고(GWITTIM_FIREBASE_PROJECT_ID가 있으면 거부) 로컬 사본(--data-dir)에만 쓴다.
"""
from __future__ import annotations

import argparse
import json
import os
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import ModuleType

from backend.contracts import schema_errors

from .external import BACKFILL_MAX_PAGES, SeenLog
from .http_polite import PoliteClient, RunLimits
from .store import JsonFileStore

KST = timezone(timedelta(hours=9), "Asia/Seoul")  # 한국은 일광절약시간 없음. Windows tzdata 불필요


BATCH_PAGES = 5  # D-059: 메뉴마다 목록 5페이지
BATCH_DETAILS = 50  # D-059: 메뉴마다 새 공고 상세 50건 (사이트 합 30건 상한 폐지)
BATCH_SECONDS = 30 * 60
COLLECT_SECONDS = 20 * 60  # --collect-only 기본 시간 상한. 교외 수집 전체 상한은 배치 스크립트가 남은 시간으로 넘긴다
BACKFILL_SECONDS = 60 * 60
BACKFILL_REQUESTS = 3000


def main(source: ModuleType, argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog=source.__name__)
    ap.add_argument("--pages", type=int, default=BATCH_PAGES, help="목록 페이지 수 (정기 배치 5)")
    ap.add_argument("--max-items", type=int, default=BATCH_DETAILS, help="새 공고 상세 요청 수 (정기 배치 50)")
    ap.add_argument("--max-seconds", type=float, default=None, help="이 출처 실행 시간 상한(초). 기본: 배치 30분, --backfill 60분")
    ap.add_argument("--backfill", action="store_true", help="수동 1회성 채우기: 목록 끝까지, 상세 건수 상한 없음, 로컬 사본만")
    ap.add_argument("--max-requests", type=int, default=None, help="HTTP 요청 상한. 기본: 배치 200건, --backfill 3000건")
    ap.add_argument("--data-dir", type=Path, default=Path("data/local"))
    ap.add_argument("--collect-only", action="store_true", help="수집·저장·대기열 등록만. 분석·게시는 analyze_queue")
    ap.add_argument("--ollama-model", default="gemma4:12b", help="로컬 Ollama 보강 분석 모델 (D-007)")
    ap.add_argument("--no-llm", action="store_true", help="규칙 분석만 사용")
    ap.add_argument("--dry-run", action="store_true", help="저장·분석·게시 없이 파싱 건수만 출력")
    args = ap.parse_args(argv)
    if args.collect_only and (args.backfill or args.dry_run):
        ap.error("--collect-only는 --backfill·--dry-run과 함께 쓰지 않습니다")
    if args.backfill and os.environ.get("GWITTIM_FIREBASE_PROJECT_ID"):
        ap.error("--backfill은 로컬 사본에만 씁니다. GWITTIM_FIREBASE_PROJECT_ID를 비우고 다시 실행하세요 (Firestore 반영은 팀장 지시 뒤)")
    if args.backfill:
        limits = RunLimits(
            list_pages_per_site=BACKFILL_MAX_PAGES,
            details_per_site=10**6,
            total_requests=args.max_requests or BACKFILL_REQUESTS,
            seconds=args.max_seconds or BACKFILL_SECONDS,
        )
    else:
        limits = RunLimits(
            list_pages_per_site=args.pages,
            details_per_site=args.max_items,
            total_requests=args.max_requests or RunLimits.total_requests,
            seconds=args.max_seconds or (COLLECT_SECONDS if args.collect_only else BATCH_SECONDS),
        )
    backfill = {"backfill": True} if args.backfill else {}

    started = datetime.now(KST)
    client = PoliteClient(limits=limits, state_path=args.data_dir / "external_site_stops.json")

    if args.dry_run:
        result = source.collect(client, pages=args.pages, max_items=args.max_items, **backfill)
        summary = {
            "source_id": source.SOURCE_ID,
            "dry_run": True,
            **_collect_counts(result),
            "schema_valid": sum(not schema_errors("raw_notice", r) for r in result.raws),
            "http": client.summary(),
        }
        print(json.dumps(summary, ensure_ascii=False))
        return

    if args.collect_only:
        _collect_only(source, args, client, started, backfill)
        return

    from backend.analysis.llm import OllamaAnalyzer
    from backend.batch import run_external
    from backend.publish import InMemorySink

    store = JsonFileStore(args.data_dir / "pipeline")
    seen_log = SeenLog(args.data_dir / "external_excluded.json")
    notices_path = args.data_dir / "notices.json"
    notices = json.loads(notices_path.read_text(encoding="utf-8")) if notices_path.exists() else {}

    project = os.environ.get("GWITTIM_FIREBASE_PROJECT_ID")
    if project:
        from backend.firebase_store import FirestoreSink, init_app

        sink = FirestoreSink(init_app(project))
    else:
        sink = InMemorySink()

    prefix = source.SOURCE_ID + ":"
    result = source.collect(
        client,
        pages=args.pages,
        max_items=args.max_items,
        **backfill,
        known=lambda nid: store.get(prefix + nid) is not None or seen_log.has(prefix + nid),
    )
    for nid, reason in result.excluded.items():
        seen_log.add(prefix + nid, reason)
    seen_log.save()

    analyzer = None if args.no_llm else OllamaAnalyzer(args.ollama_model)  # Ollama가 없으면 규칙 분석으로 자동 폴백
    report = run_external(
        result.raws,
        source_id=source.SOURCE_ID,
        store=store,
        sink=sink,
        notices=notices,
        today=datetime.now(KST).date(),
        analyzer=analyzer,
    )
    notices_path.write_text(json.dumps(notices, ensure_ascii=False, indent=1), encoding="utf-8")
    used_llm = bool(analyzer and (analyzer.llm_analyzed or analyzer.llm_failed))
    unloaded = analyzer.unload() if used_llm else False  # GPU를 바로 비운다
    finished = datetime.now(KST)
    summary = {
        "source_id": source.SOURCE_ID,
        "started_at": started.isoformat(timespec="seconds"),
        "finished_at": finished.isoformat(timespec="seconds"),
        "seconds": round((finished - started).total_seconds()),
        "llm": {
            "model": None if analyzer is None else analyzer.model,
            "used": used_llm,
            "analyzed": 0 if analyzer is None else analyzer.llm_analyzed,
            "fallback_rule_only": 0 if analyzer is None else analyzer.llm_failed,
            "unloaded": unloaded,
        },
        **_collect_counts(result),
        "http": client.summary(),
    }
    summary |= asdict(report)
    summary["sink"] = f"firestore:{project}" if project else "local"
    print(json.dumps(summary, ensure_ascii=False))


def _collect_only(source: ModuleType, args, client, started, backfill) -> None:
    from .analysis_queue import QUEUE_FILE, AnalysisQueue, collect_to_queue

    store = JsonFileStore(args.data_dir / "pipeline")
    seen_log = SeenLog(args.data_dir / "external_excluded.json")
    notices_path = args.data_dir / "notices.json"
    notices = json.loads(notices_path.read_text(encoding="utf-8")) if notices_path.exists() else {}
    queue = AnalysisQueue(args.data_dir / QUEUE_FILE)
    before = len(queue)

    prefix = source.SOURCE_ID + ":"
    result = source.collect(
        client,
        pages=args.pages,
        max_items=args.max_items,
        **backfill,
        known=lambda nid: store.get(prefix + nid) is not None or seen_log.has(prefix + nid),
    )
    for nid, reason in result.excluded.items():
        seen_log.add(prefix + nid, reason)
    seen_log.save()

    got = collect_to_queue(result.raws, source_id=source.SOURCE_ID, store=store, queue=queue, notices=notices)
    queue.save()
    finished = datetime.now(KST)
    summary = {
        "stage": "collect",
        "source_id": source.SOURCE_ID,
        "started_at": started.isoformat(timespec="seconds"),
        "finished_at": finished.isoformat(timespec="seconds"),
        "seconds": round((finished - started).total_seconds()),
        **_collect_counts(result),
        "outcomes": got["outcomes"],
        "queued": got["queued"],
        "recovered": got["recovered"],
        "queue_before": before,
        "queue_size": len(queue),
        "queue_load_error": queue.load_error,
        "http": client.summary(),
    }
    print(json.dumps(summary, ensure_ascii=False))


def _collect_counts(result) -> dict:
    return {
        "pages_read": result.pages_read,
        "listed": result.listed,
        "ended_skipped": result.ended,
        "known_skipped": result.skipped_known,
        "parsed": result.parsed,
        "audience_excluded": len(result.excluded),
        "audience_passed": len(result.raws),
        "errors": result.errors,
        "stopped": result.stopped,
    }
