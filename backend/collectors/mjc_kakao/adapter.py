"""카톡 내보내기 파일 → RawNotice (D-019).

공통 공지(broadcast) 묶음만 내보낸다. 수강 과목·개인 결과·참여자 전용 안내·자동응답은 게시하지 않는다.
본문은 학번·휴대폰·교수·수신자 이름을 가린 글이다. 알림톡은 웹 원문이 없어서 source_url은 null이다.
"""
from __future__ import annotations

from collections.abc import Iterable
from datetime import datetime, timedelta, timezone

from backend.collectors.common import content_hash

from .inbox import to_message
from .parser import read_exports, stable_id

SOURCE_ID = "mjc_kakao"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# 알림 시각과 카톡 메시지 시각이 분 경계를 넘어 1분쯤 어긋날 수 있다. 이보다 늦은 폰 메시지는 재발송으로 본다
SAME_SEND = timedelta(minutes=2)


def _same_send(phone: dict, exported: dict) -> bool:
    return datetime.fromisoformat(phone["sent_at"]) - datetime.fromisoformat(exported["sent_at"]) <= SAME_SEND


def to_raw_notices(paths: Iterable[str], collected_at: str | None = None, inbox: Iterable[dict] = ()) -> list[dict]:
    """inbox: 폰 수집기 받은편지함 문서(D-036). 내보내기와 같은 공지면 한 묶음이 된다.

    공지 ID
      · 폰 메시지가 없는 묶음: 지금까지와 같다(첫 메시지).
      · 폰 메시지가 같은 묶음의 첫 내보내기 메시지와 SAME_SEND 안: 같은 발송이다. 폰이 먼저 받은 메시지로 정한다.
        폰으로 먼저 게시한 공지에 나중에 PC 내보내기가 들어와도 ID가 그대로다.
      · 폰 메시지가 그보다 늦음: 예전 공지의 재발송이다. 이미 게시한 내보내기 기준 ID를 그대로 쓴다.
    본문·제목·종류는 내보내기 메시지가 있으면 그것을 쓴다(폰 알림 본문은 잘려 올 수 있음).
    내보내기 메시지가 없는 묶음은 source_fields.phone_preview=true (D-040). 내보내기가 있으면 키를 넣지 않는다.
    """
    _, groups = read_exports(paths, [to_message(d) for d in inbox])
    collected_at = collected_at or _now()
    raws = []
    for msgs in groups.values():
        phone = sorted((m for m in msgs if m.get("source") == "phone"), key=lambda m: m["sent_at"])
        exported = [m for m in msgs if m.get("source") != "phone"]
        body = exported[0] if exported else msgs[0]  # 본문·제목·종류
        first = msgs[0]  # 공지 ID·발송 시각
        if phone and (not exported or _same_send(phone[0], min(exported, key=lambda m: m["sent_at"]))):
            first = phone[0]
        if body["kind"] != "broadcast":
            continue
        day, hm = first["sent_at"][:10], first["sent_at"][11:16]
        raw = {
            "schema_version": "1.0",
            "source_id": SOURCE_ID,
            "source_notice_id": stable_id(first),
            "source_url": None,
            "title": body["title"] or body["room"],
            "body_text": body["masked"],
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
            "source_fields": {"channel": body["room"]},
            "attachments": [],
        }
        if not exported:  # 폰 알림으로만 받음. 알림 본문은 200자로 잘려 올 수 있다 (D-040)
            raw["source_fields"]["phone_preview"] = True
        raw["content_hash"] = content_hash(raw)
        raws.append(raw)
    return raws
