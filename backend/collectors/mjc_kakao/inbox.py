"""팀장 폰 수집기가 올린 학교 채널 알림톡 받은편지함 (D-034, D-036).

폰은 학교 채널 알림만 받아 개인 알림을 거르고 가린 뒤 올린다. 서버도 같은 파서로 한 번 더 확인한다:
공통 공지(broadcast)가 아니면 저장하지 않고, 학번·휴대폰·교수 이름을 다시 가린다.

받은편지함 글은 PC 배치가 카톡 내보내기 파일과 함께 읽어 같은 파이프라인으로 분석·게시한다(adapter.to_raw_notices).
문서 ID는 (방, 발송 분, 본문) 해시라 같은 알림을 여러 번 올려도 한 건이다.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field

from .parser import classify, clean_body, mask

INBOX = "kakao_inbox"
ROOM_PREFIX = "명지전문대학"
SENT_AT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00\+09:00$")  # 내보내기와 같은 분 단위 한국 시각
MAX_TEXT = 8000
MAX_ROOM = 40


class InboxError(ValueError):
    """올린 값의 형식이 틀림 (invalid_argument)."""


def inbox_id(room: str, sent_at: str, text: str) -> str:
    body = hashlib.sha1(re.sub(r"\s+", "", text).encode("utf-8")).hexdigest()[:12]
    return hashlib.sha1(f"{room}|{sent_at}|{body}".encode("utf-8")).hexdigest()[:16]


def accept(body: dict, received_at: str) -> tuple[str, dict] | None:
    """폰이 올린 값 → (문서 ID, 저장할 문서). 공통 공지가 아니면 None (저장하지 않음).

    형식이 틀리면 InboxError. 원문은 저장하지 않는다: 가린 본문과 폰의 분류 결과만 남긴다.
    """
    if not isinstance(body, dict):
        raise InboxError("body")
    room, sent_at, text = body.get("room"), body.get("sent_at"), body.get("text")
    if not isinstance(room, str) or not room.startswith(ROOM_PREFIX) or len(room) > MAX_ROOM:
        raise InboxError("room")
    if not isinstance(sent_at, str) or not SENT_AT_RE.match(sent_at):
        raise InboxError("sent_at")
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
        raise InboxError("text")
    cleaned = clean_body({"lines": text.splitlines()})
    # 서버에는 받는 사람 이름 목록이 없다. 폰이 이미 가렸고, 학번·수강 과목 같은 규칙은 이름 없이도 걸린다
    if classify(cleaned, ()) != "broadcast":
        return None
    masked = mask(cleaned, ())
    doc = {
        "room": room,
        "sent_at": sent_at,
        "text": masked,
        "received_at": received_at,
        "phone": {k: body[k] for k in ("classification", "model_version", "app_version") if k in body},
    }
    return inbox_id(room, sent_at, masked), doc


def to_message(doc: dict) -> dict:
    """받은편지함 문서 → 파서 메시지 (parse_export와 같은 모양, source='phone')."""
    return {"room": doc["room"], "sender": doc["room"], "sent_at": doc["sent_at"], "lines": doc["text"].splitlines(),
            "source": "phone"}


@dataclass
class InMemoryInbox:
    docs: dict[str, dict] = field(default_factory=dict)

    def put(self, doc_id: str, doc: dict) -> bool:
        """처음 받은 알림이면 True. 같은 알림을 다시 올려도 처음 것을 그대로 둔다."""
        if doc_id in self.docs:
            return False
        self.docs[doc_id] = doc
        return True

    def list(self) -> list[dict]:
        return list(self.docs.values())
