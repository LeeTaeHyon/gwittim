"""공고 식별자와 content_hash 계산 (SPEC §5 RawNotice, §6 수집·분석 2·3)."""
from __future__ import annotations

import hashlib
import json
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


def normalize_url(url: str) -> str:
    """공고 ID가 없을 때 쓰는 정규화 URL: scheme·host 소문자, 쿼리 정렬, fragment 제거."""
    parts = urlsplit(url.strip())
    query = urlencode(sorted(parse_qsl(parts.query, keep_blank_values=True)))
    path = parts.path or "/"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, query, ""))


def notice_key(raw: dict) -> str:
    """출처 ID + 공고 ID. 공고 ID가 없으면 출처 ID + 정규화 URL."""
    local = raw["source_notice_id"] or "url:" + normalize_url(raw["source_url"])
    return f"{raw['source_id']}:{local}"


def content_hash(raw: dict) -> str:
    """의미 있는 내용의 해시. collected_at 등 매번 바뀌는 값은 넣지 않는다.

    대상: title, body_text, published, source_fields, attachments[].file_name
    """
    payload = {
        "title": raw["title"],
        "body_text": raw["body_text"],
        "published": raw["published"],
        "source_fields": raw["source_fields"],
        "attachments": [a["file_name"] for a in raw["attachments"]],
    }
    canonical = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()
