"""카톡 내보내기 파일 → RawNotice (D-016).

공통 공지(broadcast) 묶음만 내보낸다. 수강 과목·개인 결과·참여자 전용 안내·자동응답은 게시하지 않는다.
본문은 학번·휴대폰·교수·수신자 이름을 가린 글이다. 알림톡은 웹 원문이 없어서 source_url은 null이다.
"""
from __future__ import annotations

from collections.abc import Iterable
from datetime import datetime, timezone

from backend.collectors.common import content_hash

from .parser import read_exports, stable_id

SOURCE_ID = "mjc_kakao"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def to_raw_notices(paths: Iterable[str], collected_at: str | None = None) -> list[dict]:
    _, groups = read_exports(paths)
    collected_at = collected_at or _now()
    raws = []
    for msgs in groups.values():
        first = msgs[0]
        if first["kind"] != "broadcast":
            continue
        day, hm = first["sent_at"][:10], first["sent_at"][11:16]
        raw = {
            "schema_version": "1.0",
            "source_id": SOURCE_ID,
            "source_notice_id": stable_id(first),
            "source_url": None,
            "title": first["title"] or first["room"],
            "body_text": first["masked"],
            "published": {
                "date": day,
                "time": hm,
                "timezone": "Asia/Seoul",
                "precision": "minute",
                "evidence": f"카카오톡 수신 {day} {hm}",
            },
            "collected_at": collected_at,
            "content_hash": "",
            # 재발송 횟수·마지막 발송 시각은 넣지 않는다 (같은 공지를 다시 보내도 수정본으로 보지 않음)
            "source_fields": {"channel": first["room"]},
            "attachments": [],
        }
        raw["content_hash"] = content_hash(raw)
        raws.append(raw)
    return raws
