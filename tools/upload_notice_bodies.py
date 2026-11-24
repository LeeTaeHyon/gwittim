"""기존 공고 본문을 서버 전용 모음 notice_bodies에 올리는 도구 (docs/agent-detail-body-spec.md S3).

기본은 건조 실행이다: 올릴 건수와 빠지는 건수·사유만 출력하고 아무것도 쓰지 않는다. 본문은 출력하지 않는다.

  uv run python tools/upload_notice_bodies.py --data C:/path/to/data/local        # 건조 실행
  GWITTIM_FIREBASE_PROJECT_ID=<id> uv run python tools/upload_notice_bodies.py --data ... --write   # 실제 쓰기(팀장 지시 뒤에만)

입력: <data>/pipeline/records.json(raw.body_text)과 <data>/notices.json(게시 여부·제목).
올리는 규칙은 배치의 게시 시점 쓰기와 같다(backend.publish.body_for_storage·sync_body):
게시한 공고만, 명단형 제목과 본문 20자 미만은 뺀다. 이미 같은 본문이 올라가 있으면 다시 쓰지 않는다.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.agent.prompt import BODY_MAX_CHARS  # noqa: E402
from backend.publish.publisher import ROSTER, body_for_storage, sync_body  # noqa: E402

NOT_PUBLISHED = "게시하지 않는 공고"
NO_RECORD = "수집 원문 없음"
ROSTER_TITLE = "명단형 제목"
TOO_SHORT = "본문 20자 미만(이미지·첨부만)"


def classify(notices: dict[str, dict], records: dict[str, dict]) -> tuple[dict[str, str], dict[str, str]]:
    """(올릴 것 {key: 본문}, 빠지는 것 {key: 사유})."""
    upload: dict[str, str] = {}
    skipped: dict[str, str] = {}
    for key, notice in notices.items():
        if notice.get("publication_status") != "published":
            skipped[key] = NOT_PUBLISHED
            continue
        record = records.get(key)
        if record is None:
            skipped[key] = NO_RECORD
            continue
        raw_body = (record.get("raw") or {}).get("body_text")
        text = body_for_storage(notice.get("title", ""), raw_body)
        if text is not None:
            upload[key] = text
        elif ROSTER.search(notice.get("title", "")):
            skipped[key] = ROSTER_TITLE
        else:
            skipped[key] = TOO_SHORT
    return upload, skipped


def summarize(upload: dict[str, str], skipped: dict[str, str]) -> list[str]:
    reasons = Counter(skipped.values())
    over = sum(1 for t in upload.values() if len(t) > BODY_MAX_CHARS)
    lines = [f"올릴 공고: {len(upload)}건 (분석 입력은 앞 {BODY_MAX_CHARS:,}자까지, 넘는 본문 {over}건)", f"빠지는 공고: {len(skipped)}건"]
    lines += [f"  - {reason}: {n}건" for reason, n in sorted(reasons.items())]
    return lines


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=Path("data/local"), help="data/local 폴더 (pipeline/records.json, notices.json)")
    ap.add_argument("--write", action="store_true", help="Firestore에 실제로 쓴다. 없으면 건조 실행")
    args = ap.parse_args(argv)

    records = json.loads((args.data / "pipeline" / "records.json").read_text(encoding="utf-8"))
    notices = json.loads((args.data / "notices.json").read_text(encoding="utf-8"))
    upload, skipped = classify(notices, records)
    print("\n".join(summarize(upload, skipped)))

    if not args.write:
        print("건조 실행: 아무것도 쓰지 않았습니다. 실제로 올리려면 --write")
        return 0

    project = os.environ.get("GWITTIM_FIREBASE_PROJECT_ID")
    if not project:
        print("GWITTIM_FIREBASE_PROJECT_ID가 없습니다.", file=sys.stderr)
        return 2
    from backend.firebase_store import FirestoreSink, init_app

    sink = FirestoreSink(init_app(project))
    written = 0
    for key, text in upload.items():
        notice = notices[key]
        current = sink.get_body(notice["notice_id"])
        if current is not None and current.get("body_text") == text:
            continue  # 이미 같은 본문
        sync_body(notice, text, sink)
        written += 1
    print(f"쓴 문서: {written}건, 이미 같아서 건너뜀: {len(upload) - written}건")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
