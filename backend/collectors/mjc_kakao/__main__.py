"""알림톡 수집 실행 (D-019). PC 카톡에서 학교 채널 대화를 내보낸 뒤 손으로 실행한다.

uv run python -m backend.collectors.mjc_kakao --export-dir <내보내기 txt 폴더>              # 로컬 파일만 (data/local/)
uv run python -m backend.collectors.mjc_kakao --export-dir <폴더> --no-llm                   # Ollama 없이 (모델만)
GWITTIM_FIREBASE_PROJECT_ID=<id> uv run python -m backend.collectors.mjc_kakao --export-dir <폴더>  # Firestore에 게시
uv run python -m backend.collectors.mjc_kakao --export-dir <폴더> --inbox-file <받은편지함.jsonl>  # 폰 수집분을 파일로 (확인용)
uv run python -m backend.collectors.mjc_kakao --export-dir <기준 폴더> <자동 내보내기 폴더>      # 방마다 가장 새 파일만

폴더를 여러 개 주면 방마다 파일 이름(KakaoTalk_날짜_시각_방.txt)이 가장 늦은 파일 하나만 읽는다.
내보내기는 그때까지의 대화를 통째로 담으므로 새 파일 하나가 예전 파일을 대신한다(scripts/export_kakao.ps1).

Firestore 프로젝트를 주면 팀장 폰 수집기가 올린 받은편지함(kakao_inbox, D-036)도 함께 읽는다.
폰 알림과 PC 내보내기의 같은 공지는 한 공고가 된다(adapter.to_raw_notices).

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
from .parser import room_of

KST = timezone(timedelta(hours=9), "Asia/Seoul")  # 한국은 일광절약시간 없음


def latest_exports(dirs: list[Path]) -> list[str]:
    """폴더들의 *.txt 중 방마다 파일 이름이 가장 늦은 것 (이름이 KakaoTalk_YYYYMMDD_HHMM_… 라 글자 순 = 시간 순)."""
    latest: dict[str, str] = {}
    for d in dirs:
        for p in glob.glob(str(d / "*.txt")):
            room = room_of(p)
            if room not in latest or os.path.basename(p) > os.path.basename(latest[room]):
                latest[room] = p
    return sorted(latest.values())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--export-dir", type=Path, nargs="+", required=True,
                    help="KakaoTalk_*.txt 내보내기 파일이 있는 폴더. 여러 개면 방마다 가장 새 파일만")
    ap.add_argument("--inbox-file", type=Path, help="받은편지함 문서 JSONL (Firestore 대신, 확인용)")
    ap.add_argument("--no-inbox", action="store_true", help="Firestore 받은편지함을 읽지 않는다")
    ap.add_argument("--data-dir", type=Path, default=Path("data/local"))
    ap.add_argument("--ollama-model", default="gemma4:12b", help="요약·마감 보강과 애매한 분류에 쓸 모델 (D-007)")
    ap.add_argument("--no-llm", action="store_true", help="Gemma 없이: 규칙 분석 + 내 모델만")
    args = ap.parse_args()

    paths = latest_exports(args.export_dir)
    project = os.environ.get("GWITTIM_FIREBASE_PROJECT_ID")
    firebase = None
    if project:
        from backend.firebase_store import init_app

        firebase = init_app(project)

    inbox: list[dict] = []
    if args.inbox_file:
        inbox = [json.loads(l) for l in args.inbox_file.read_text(encoding="utf-8").splitlines() if l.strip()]
    elif firebase is not None and not args.no_inbox:
        from backend.firebase_store import FirestoreKakaoInbox

        inbox = FirestoreKakaoInbox(firebase).list()
    if not paths and not inbox:
        raise SystemExit(f"내보내기 파일도 받은편지함 글도 없습니다: {', '.join(map(str, args.export_dir))}")
    raws = to_raw_notices(paths, inbox=inbox)

    store = JsonFileStore(args.data_dir / "pipeline")
    notices_path = args.data_dir / "notices.json"
    notices = json.loads(notices_path.read_text(encoding="utf-8")) if notices_path.exists() else {}

    if firebase is not None:
        from backend.firebase_store import FirestoreSink

        sink = FirestoreSink(firebase)
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
    summary["inbox"] = len(inbox)  # 폰 수집기가 올린 알림 수 (D-036)
    summary["decided_by"] = dict(analyzer.decided_by)  # model / gemma / model_gemma_failed (새로 분석한 공고만)
    summary["sink"] = f"firestore:{project}" if project else "local"
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
