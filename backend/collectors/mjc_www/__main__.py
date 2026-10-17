"""팀장 PC 로컬 배치 실행 (D-006: 3시간마다). 수집 → 파이프라인 → 분석 → 게시 → 사라진 공고 확인.

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
    ap.add_argument("--no-llm", action="store_true", help="규칙 분석만 사용")
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

    report = run_batch(
        (b for b in BOARDS.values() if b.active),
        store=store,
        sink=sink,
        notices=notices,
        today=datetime.now(KST).date(),
        pages=args.pages,
        max_items=args.max_items,
        analyzer=None if args.no_llm else OllamaAnalyzer(args.ollama_model),  # Ollama가 없으면 규칙 분석으로 자동 폴백
        delay=args.delay,
    )
    notices_path.write_text(json.dumps(notices, ensure_ascii=False, indent=1), encoding="utf-8")
    summary = asdict(report)
    summary["fetch_errors"] = len(report.fetch_errors)
    summary["sink"] = f"firestore:{project}" if project else "local"
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
