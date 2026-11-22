"""평가셋 공고를 지금 분석기로 다시 분석해 notices JSON을 만든다. 외부 사이트 요청 없음(저장된 원본만 사용).

입력: 정답표의 notice_id 열, 원본 records.json(여러 개 가능, 먼저 나온 파일이 우선)
출력: {notice_id: Notice} JSON. 채점은 tools/eval_board_extraction.py --notices <출력>

LLM(Ollama gemma4)은 temperature 0이라 같은 입력에는 거의 같게 나오지만 완전히 결정적이지는 않다.
전후 비교는 같은 옵션(--no-llm 여부, 모델)으로 돌린다.

실행 예:
  uv run python tools/reanalyze_eval.py --out data/local/eval_common/notices_before.json
  uv run python tools/reanalyze_eval.py --gold <csv> --records <a.json> --records <b.json> --out <out.json> [--no-llm]
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # python tools/x.py 로 돌릴 때 필요

from backend.analysis.llm import OllamaAnalyzer  # noqa: E402
from backend.analysis.notice import build_notice  # noqa: E402
from backend.collectors.common import RawRecord  # noqa: E402

TODAY = date(2026, 11, 22)  # lifecycle 계산용 고정일(전후 비교에서 흔들리지 않게)


def _data_local() -> Path | None:
    """worktree에는 data/가 없으니, 위로 올라가며 data/local이 있는 가장 가까운 폴더를 쓴다. 없으면 --gold·--records를 직접 줘야 한다."""
    for parent in Path(__file__).resolve().parents:
        if (parent / "data" / "local").is_dir():
            return parent / "data" / "local"
    return None


def main() -> None:
    local = _data_local()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--gold", type=Path, default=local and local / "eval_common/gold.csv", required=local is None)
    ap.add_argument("--records", type=Path, action="append",
                    help="원본 records.json (기본: 명지·숭의 파이프라인 records.json)")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--no-llm", action="store_true", help="규칙 분석만")
    ap.add_argument("--ollama-model", default="gemma4:12b")
    args = ap.parse_args()
    if not args.records and local is None:
        raise SystemExit("--records가 필요함")
    record_paths = args.records or [local / "pipeline/records.json", local / "sewu_score/pipeline/records.json"]

    records: dict[str, dict] = {}
    for path in record_paths:
        for key, rec in json.loads(path.read_text(encoding="utf-8")).items():
            records.setdefault(key, rec)

    ids = [r["notice_id"] for r in csv.DictReader(args.gold.open(encoding="utf-8-sig"))]
    missing = [i for i in ids if i not in records]
    if missing:
        raise SystemExit(f"원본 없음: {missing}")

    analyzer = None if args.no_llm else OllamaAnalyzer(args.ollama_model, timeout=300)
    out, problems = {}, {}
    for i, nid in enumerate(ids, 1):
        notice, issues = build_notice(RawRecord(**records[nid]), today=TODAY, analyzer=analyzer)
        out[nid] = notice
        if issues:
            problems[nid] = issues
        print(f"[{i}/{len(ids)}] {nid} {notice['analysis_version']}", file=sys.stderr)
    args.out.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    if analyzer:
        analyzer.unload()
        print(f"LLM 분석 {analyzer.llm_analyzed}건, 실패(규칙만) {analyzer.llm_failed}건", file=sys.stderr)
    for nid, issues in problems.items():
        print(f"검증 문제 {nid}: {issues}", file=sys.stderr)
    print(f"{len(out)}건 -> {args.out}")


if __name__ == "__main__":
    main()
