"""학교 게시판의 지난 공고를 한 번 더 모아 관심사 학습 보강용으로 저장한다 (D-019 후속).

정기 수집(D-006)은 게시판마다 최근 2페이지만 본다. 학습 예시를 늘리려고 그보다 오래된 페이지까지 한 번만 모은다.
앱 파이프라인·Firestore에는 넣지 않고 원문만 저장한다. 요청 사이 1초씩 쉰다 (수집기 기본값).

출력: kakaoTalk_data/processed/board_history.json  {"<source_id>:<source_notice_id>": {"raw": RawNotice}}
  board_notices.py가 records.json과 합쳐 board_notices.jsonl을 만든다.

사용 (저장소 루트에서, 수집기 의존성이 있는 백엔드 환경): uv run python localModel/board_history.py [--pages 10]
"""
import argparse
import json
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))  # 저장소 루트 (backend 패키지)

from backend.collectors.mjc_www.adapter import BOARDS, collect  # noqa: E402

OUT = os.path.join(BASE, "kakaoTalk_data", "processed", "board_history.json")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", type=int, default=10)
    args = ap.parse_args()

    records = {}
    for board in BOARDS.values():
        if not board.active:
            continue
        raws, errors = collect(board, pages=args.pages)
        for raw in raws:
            records[f"{raw['source_id']}:{raw['source_notice_id']}"] = {"raw": raw}
        print(f"{board.name}: {len(raws)}건, 오류 {len(errors)}건", flush=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False)
    print(f"전체 {len(records)}건 → {OUT}")


if __name__ == "__main__":
    main()
