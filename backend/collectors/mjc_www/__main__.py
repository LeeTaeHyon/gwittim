"""팀장 PC 로컬 배치 실행 (D-006: 매일 09:00·18:00, Windows 작업 스케줄러). 수집 → 파이프라인 → 분석 → 게시 → 사라진 공고 확인.

uv run python -m backend.collectors.mjc_www                       # 로컬 파일만 (data/local/)
uv run python -m backend.collectors.mjc_www --pages 1 --max-items 5  # 빠른 확인
GWITTIM_FIREBASE_PROJECT_ID=<id> uv run python -m backend.collectors.mjc_www  # Firestore에 게시
(에뮬레이터: FIRESTORE_EMULATOR_HOST=127.0.0.1:8080, 프로젝트 ID demo-gwittim)
"""
from __future__ import annotations

import argparse
import json
import os
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from backend.analysis.extract_model import MODEL_SUBDIR, load_if_present
from backend.analysis.llm import OllamaAnalyzer
from backend.batch import run_batch
from backend.collectors.common import JsonFileStore
from backend.publish import InMemorySink

from .adapter import BOARDS

KST = timezone(timedelta(hours=9), "Asia/Seoul")  # 한국은 일광절약시간 없음. Windows tzdata 불필요


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", type=int, default=2)  # D-006
    ap.add_argument("--max-items", type=int, default=None)
    ap.add_argument("--delay", type=float, default=1.0)
    ap.add_argument("--data-dir", type=Path, default=Path("data/local"))
    ap.add_argument("--ollama-model", default="gemma4:12b", help="로컬 Ollama 보강 분석 모델 (D-007)")
    ap.add_argument("--no-llm", action="store_true", help="Gemma를 쓰지 않음 (요약 없음)")
    ap.add_argument("--extract-model", type=Path, default=None, help="자체 공고 줄 분류 모델 폴더 (D-042). 기본 <data-dir>/models/extract-v1. 없으면 Gemma가 추출 보강")
    ap.add_argument("--no-extract-model", action="store_true", help="자체 모델을 쓰지 않음")
    args = ap.parse_args()

    store = JsonFileStore(args.data_dir / "pipeline")
    notices_path = args.data_dir / "notices.json"
    notices = json.loads(notices_path.read_text(encoding="utf-8")) if notices_path.exists() else {}

    project = os.environ.get("GWITTIM_FIREBASE_PROJECT_ID")
    if project:
        from backend.firebase_store import FirestoreSink, init_app

        sink = FirestoreSink(init_app(project))
    else:
        sink = InMemorySink()

    started = datetime.now(KST)
    # 자체 모델이 있으면 마감·조건 추출을 맡고 Gemma는 요약만 (D-042). Ollama가 없으면 요약 없이 진행
    extract = None if args.no_extract_model else load_if_present(args.extract_model or args.data_dir / MODEL_SUBDIR)
    if args.no_llm:
        analyzer = extract
    else:
        analyzer = OllamaAnalyzer(args.ollama_model, base=extract, extract=extract is None)
    report = run_batch(
        (b for b in BOARDS.values() if b.active),
        store=store,
        sink=sink,
        notices=notices,
        today=datetime.now(KST).date(),
        pages=args.pages,
        max_items=args.max_items,
        analyzer=analyzer,
        delay=args.delay,
    )
    notices_path.write_text(json.dumps(notices, ensure_ascii=False, indent=1), encoding="utf-8")
    llm = analyzer if isinstance(analyzer, OllamaAnalyzer) else None
    used_llm = bool(llm and (llm.llm_analyzed or llm.llm_failed))
    unloaded = llm.unload() if used_llm else False  # GPU를 바로 비운다
    finished = datetime.now(KST)
    summary = {
        "started_at": started.isoformat(timespec="seconds"),
        "finished_at": finished.isoformat(timespec="seconds"),
        "seconds": round((finished - started).total_seconds()),
        "llm": {
            "model": None if llm is None else llm.model,
            "used": used_llm,
            "analyzed": 0 if llm is None else llm.llm_analyzed,
            "fallback_rule_only": 0 if llm is None else llm.llm_failed,
            "unloaded": unloaded,
        },
        "extract_model": {
            "version": None if extract is None else extract.version,
            "analyzed": 0 if extract is None else extract.model_analyzed,
            "fallback_rule_only": 0 if extract is None else extract.model_failed,
        },
    }
    summary |= asdict(report)
    summary["fetch_errors"] = len(report.fetch_errors)
    summary["sink"] = f"firestore:{project}" if project else "local"
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
