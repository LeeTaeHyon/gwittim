"""알림톡 공지마다 서버 분류기(backend/classifier)의 확률과 판정을 JSONL로 낸다.

기기 안 계산(apps/mobile/lib/classifier)이 서버와 같은지 비교할 때 기준값으로 쓴다.
원문은 출력에 넣지 않는다. 출력 파일은 저장소에 넣지 않는다(data/local/은 git 제외).

한 줄: id, interest_probs(꼬리표 순서 + 마지막 기타), category_probs, interest_ids, category, unsure

실행
  uv run python tools/dump_classifier_probs.py
  cd apps/mobile && dart run tool/classifier_parity.dart
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))  # python tools/x.py 로 돌릴 때 필요

from backend.classifier import cascade  # noqa: E402
from backend.classifier.text_model import TextModel, text_of  # noqa: E402

NOTICES = ROOT / "localModel/kakaoTalk_data/processed/notices.jsonl"
OUT = ROOT / "data/local/classifier_server_probs.jsonl"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="서버 분류기의 확률·판정을 공지별로 낸다")
    ap.add_argument("--notices", type=Path, default=NOTICES)
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args(argv)

    interest = TextModel.load(cascade.INTEREST_MODEL)
    category = TextModel.load(cascade.CATEGORY_MODEL)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with args.notices.open(encoding="utf-8") as src, args.out.open("w", encoding="utf-8", newline="\n") as dst:
        for line in src:
            if not line.strip():
                continue
            n = json.loads(line)
            doc = text_of(n["title"], n["text"])
            result = cascade.classify(n["title"], n["text"])  # Gemma 없이: 모델 판정과 애매함만
            dst.write(json.dumps({
                "id": n["id"],
                "interest_probs": interest.probs(doc),
                "category_probs": category.probs(doc),
                "interest_ids": result.interest_ids,
                "category": result.category,
                "unsure": bool(result.unsure),
            }) + "\n")
            count += 1
    print(f"{count}건 → {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
