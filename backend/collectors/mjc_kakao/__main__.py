"""알림톡 수집 실행 (D-019). PC 카톡에서 학교 채널 대화를 내보낸 뒤 손으로 실행한다.

uv run python -m backend.collectors.mjc_kakao --export-dir <내보내기 txt 폴더>              # 로컬 파일만 (data/local/)
uv run python -m backend.collectors.mjc_kakao --export-dir <폴더> --no-llm                   # Ollama 없이 (모델만)
GWITTIM_FIREBASE_PROJECT_ID=<id> uv run python -m backend.collectors.mjc_kakao --export-dir <폴더>  # Firestore에 게시

게시판 공고와 짝을 찾으므로(D-025) 게시판 배치(backend.collectors.mjc_www)가 끝난 뒤 실행한다.

게시판 배치(backend.collectors.mjc_www)와 같은 data/local 기록을 쓰므로 두 배치를 동시에 돌리지 않는다.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from backend.analysis.kakao import KakaoAnalyzer
from backend.analysis.llm import OllamaAnalyzer
from backend.batch import run_kakao
from backend.classifier.cascade import ollama
from backend.collectors.common import JsonFileStore
from backend.publish import InMemorySink

from .adapter import to_raw_notices

KST = timezone(timedelta(hours=9), "Asia/Seoul")  # 한국은 일광절약시간 없음


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--export-dir", type=Path, required=True, help="KakaoTalk_*.txt 내보내기 파일이 있는 폴더")
    ap.add_argument("--data-dir", type=Path, default=Path("data/local"))
    ap.add_argument("--ollama-model", default="gemma4:12b", help="요약·마감 보강과 애매한 분류에 쓸 모델 (D-007)")
    ap.add_argument("--no-llm", action="store_true", help="Gemma 없이: 규칙 분석 + 내 모델만")
    args = ap.parse_args()

    paths = sorted(glob.glob(str(args.export_dir / "*.txt")))
    if not paths:
        raise SystemExit(f"내보내기 파일이 없습니다: {args.export_dir}")
    raws = to_raw_notices(paths)

    store = JsonFileStore(args.data_dir / "pipeline")
    notices_path = args.data_dir / "notices.json"
    notices = json.loads(notices_path.read_text(encoding="utf-8")) if notices_path.exists() else {}

    project = os.environ.get("GWITTIM_FIREBASE_PROJECT_ID")
    if project:
        from backend.firebase_store import FirestoreSink, init_app

        sink = FirestoreSink(init_app(project))
    else:
        sink = InMemorySink()

    analyzer = (
        KakaoAnalyzer()
        if args.no_llm
        else KakaoAnalyzer(OllamaAnalyzer(args.ollama_model), gemma=ollama(args.ollama_model))
    )
    report = run_kakao(raws, store=store, sink=sink, notices=notices, today=datetime.now(KST).date(), analyzer=analyzer)
    notices_path.write_text(json.dumps(notices, ensure_ascii=False, indent=1), encoding="utf-8")
    summary = asdict(report)
    summary["fetch_errors"] = len(report.fetch_errors)
    summary["files"] = len(paths)
    summary["decided_by"] = dict(analyzer.decided_by)  # model / gemma / model_gemma_failed (새로 분석한 공고만)
    summary["sink"] = f"firestore:{project}" if project else "local"
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
