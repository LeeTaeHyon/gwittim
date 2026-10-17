"""팀장 PC 로컬 배치 실행: 활성 게시판 수집 → 파이프라인 → 분석. 결과는 data/local/ (커밋 금지).

uv run python -m backend.collectors.mjc_www            # D-006: 3시간마다 실행
uv run python -m backend.collectors.mjc_www --pages 1 --max-items 5   # 빠른 확인
"""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from backend.analysis import build_notice
from backend.collectors.common import JsonFileStore, Outcome, ingest

from .adapter import BOARDS, collect

KST = timezone(timedelta(hours=9), "Asia/Seoul")  # 한국은 일광절약시간 없음. Windows tzdata 불필요


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", type=int, default=2)  # D-006
    ap.add_argument("--max-items", type=int, default=None)
    ap.add_argument("--delay", type=float, default=1.0)
    ap.add_argument("--data-dir", type=Path, default=Path("data/local"))
    args = ap.parse_args()

    store = JsonFileStore(args.data_dir / "pipeline")
    notices_path = args.data_dir / "notices.json"
    notices = json.loads(notices_path.read_text(encoding="utf-8")) if notices_path.exists() else {}
    today = datetime.now(KST).date()

    summary = {o.value: 0 for o in Outcome} | {"review_pending": 0, "fetch_errors": 0}
    for board in (b for b in BOARDS.values() if b.active):
        raws, errors = collect(board, pages=args.pages, max_items=args.max_items, delay=args.delay)
        summary["fetch_errors"] += len(errors)
        for raw in raws:
            result = ingest(raw, store)
            summary[result.outcome.value] += 1
            if result.outcome is Outcome.REJECTED:
                continue
            record = store.records[result.key]
            notice, issues = build_notice(record, today=today, previous=notices.get(result.key))
            notices[result.key] = notice
            summary["review_pending"] += bool(issues)

    notices_path.write_text(json.dumps(notices, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
