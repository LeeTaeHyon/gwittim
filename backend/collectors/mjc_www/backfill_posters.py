"""게시된 명지 공고의 상세를 다시 읽어 poster_url만 채운 로컬 사본을 만든다."""
from __future__ import annotations

import argparse
import json
import re
import time
from pathlib import Path

from .adapter import BOARDS, http_fetch, view_url
from .parser import parse_detail


def refresh(notices, *, fetch=http_fetch, delay=1.0, db=None):
    """실패하거나 읽는 동안 게시본이 바뀐 공고는 보존한다. 분석기를 사용하지 않는다."""
    updated = checked = failed = 0
    for key, notice in notices.items():
        board = BOARDS.get(notice["source_id"])
        if not board or not board.active or notice["publication_status"] != "published":
            continue
        source, _, number = key.partition(":")
        if source != board.source_id or not re.fullmatch(r"BD[0-9]+", number):
            continue
        if checked:
            time.sleep(delay)
        checked += 1
        try:
            url = view_url(board, board.bbs_mst_idx, number)
            if db is not None:
                from google.cloud import firestore
                ref = db.collection("notices").document(notice["notice_id"])
                snap = ref.get()
                current = snap.to_dict() or {}
                if (current.get("source_url") != notice["source_url"]
                        or current.get("publication_status") != "published"):
                    continue
            poster = parse_detail(fetch(url), url).poster_url
            if db is not None and current.get("poster_url") != poster:
                ref.update({"poster_url": poster or firestore.DELETE_FIELD},
                           option=db.write_option(last_update_time=snap.update_time))
            if notice.get("poster_url") != poster:
                if poster:
                    notice["poster_url"] = poster
                else:
                    notice.pop("poster_url", None)
                updated += 1
        except Exception as error:
            print(f"{key}: {type(error).__name__}")
            failed += 1
    return {"checked": checked, "updated": updated, "failed": failed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="배치 notices.json")
    parser.add_argument("output", type=Path, help="검증할 새 로컬 사본")
    parser.add_argument("--firestore-project", help="명시한 경우에만 같은 포스터 필드를 공개본에 반영")
    args = parser.parse_args()
    if args.input.resolve() == args.output.resolve() or args.output.exists():
        parser.error("새 출력 경로를 지정하십시오")
    db = None
    if args.firestore_project:
        from firebase_admin import firestore
        from backend.firebase_store import init_app
        db = firestore.client(init_app(args.firestore_project))
    notices = json.loads(args.input.read_text(encoding="utf-8"))
    report = refresh(notices, db=db)
    with args.output.open("x", encoding="utf-8") as f:
        json.dump(notices, f, ensure_ascii=False, indent=1)
    print(json.dumps(report))
    if report["failed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
