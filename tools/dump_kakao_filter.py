"""카톡 내보내기의 모든 메시지에 대해 파서의 종류 판정·가림 결과를 JSONL로 낸다 (D-034).

기기 안 이식이 실제 메시지 전체에서 파서와 같은지 볼 때 기준값으로 쓴다.
원문이 들어가므로 출력은 data/local/(git 제외)에만 둔다.

첫 줄: {"names": [...]}   그다음 메시지마다: room, raw(줄을 이은 원문), clean, kind, masked, title

실행
  uv run python tools/dump_kakao_filter.py
  cd apps/mobile && dart run tool/kakao_filter_parity.dart
"""
from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))  # python tools/x.py 로 돌릴 때 필요

from backend.collectors.mjc_kakao.parser import detect_names, read_exports  # noqa: E402

EXPORTS = ROOT / "localModel/kakaoTalk_data"
OUT = ROOT / "data/local/kakao_filter_server.jsonl"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="내보내기 메시지별 파서 판정·가림 결과")
    ap.add_argument("--exports", type=Path, default=EXPORTS, help="KakaoTalk_*.txt가 있는 폴더")
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args(argv)

    paths = sorted(glob.glob(str(args.exports / "KakaoTalk_*.txt")))
    if not paths:
        print(f"{args.exports}에 KakaoTalk_*.txt 없음")
        return 1
    msgs, _ = read_exports(paths)
    names = detect_names(m["text"] for m in msgs)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({"names": sorted(names)}, ensure_ascii=False) + "\n")
        for m in msgs:
            f.write(json.dumps({
                "room": m["room"], "raw": "\n".join(m["lines"]), "clean": m["text"],
                "kind": m["kind"], "masked": m["masked"], "title": m["title"],
            }, ensure_ascii=False) + "\n")
    print(f"파일 {len(paths)}개, 메시지 {len(msgs)}건 → {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
