"""명지전문대 www 게시판 어댑터: 게시판 설정 → RawNotice. DB 저장은 하지 않는다 (D-002).

게시판 추가는 BOARDS에 한 줄을 넣고 active=True로 바꾸면 된다 (source-review §5).
P0 활성 게시판은 공지사항·장학공지·채용공지·근로게시판 4개다 (D-013).
"""
from __future__ import annotations

import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import PurePosixPath

from backend.collectors.common import content_hash

from .parser import parse_detail, parse_list

BASE_URL = "https://www.mjc.ac.kr"
USER_AGENT = "GwittimCollector/0.1 (school contest project; min interval 3h)"


@dataclass(frozen=True)
class Board:
    source_id: str
    name: str
    menu_idx: str
    bbs_mst_idx: str
    active: bool


BOARDS: dict[str, Board] = {
    b.source_id: b
    for b in [
        Board("mjc_www_notice", "공지사항", "66", "BM0000000026", active=True),
        Board("mjc_www_scholarship", "장학공지", "208", "BM0000000032", active=True),
        Board("mjc_www_job", "채용공지", "2617", "BM0000002077", active=True),
        Board("mjc_www_promotion", "홍보게시판", "2711", "BM0000002205", active=False),
        Board("mjc_www_work", "근로게시판", "3002", "BM0000002478", active=True),
        Board("mjc_www_minority", "소수학생게시판", "3145", "", active=False),
    ]
}

Fetcher = Callable[[str], str]


# D-006: 일시 장애(네트워크·429·5xx)만 재시도, 최대 2회 재시도, 대기 5초 → 15초
RETRY_WAITS = (5.0, 15.0)


def _retryable(error: Exception) -> bool:
    if isinstance(error, urllib.error.HTTPError):
        return error.code == 429 or error.code >= 500
    return isinstance(error, (urllib.error.URLError, TimeoutError, ConnectionError))


def http_fetch(url: str, *, waits: tuple[float, ...] = RETRY_WAITS, sleep=time.sleep) -> str:
    """403·404 등은 재시도하지 않고 바로 실패로 올린다 (단일 실패로 삭제 확정 금지는 파이프라인 규칙)."""
    for attempt in range(len(waits) + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read().decode("utf-8", "replace")
        except Exception as e:
            if attempt == len(waits) or not _retryable(e):
                raise
            sleep(waits[attempt])
    raise AssertionError("unreachable")


def probe(url: str, *, opener=urllib.request.urlopen) -> str:
    """원문이 아직 있는지 확인한다: "found" | "not_found" | "error".

    학교 사이트는 없는 글을 404가 아니라 /error 로 리다이렉트한다 (2026-10-18 확인).
    """
    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with opener(req, timeout=30) as resp:
            final = urllib.parse.urlsplit(resp.geturl()).path
            return "not_found" if final.startswith("/error") else "found"
    except urllib.error.HTTPError as e:
        return "not_found" if e.code in (404, 410) else "error"
    except Exception:
        return "error"


def list_url(board: Board, page: int) -> str:
    return f"{BASE_URL}/bbs/data/list.do?menu_idx={board.menu_idx}&pageIndex={page}"


def view_url(board: Board, bbs_mst_idx: str, data_idx: str) -> str:
    return f"{BASE_URL}/bbs/data/view.do?menu_idx={board.menu_idx}&bbs_mst_idx={bbs_mst_idx}&data_idx={data_idx}"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _attachment(name: str) -> dict:
    suffix = PurePosixPath(name).suffix.lower().lstrip(".")
    return {"file_name": name, "url": None, "type": suffix or None}


def collect(
    board: Board,
    *,
    pages: int = 1,
    max_items: int | None = None,
    fetch: Fetcher = http_fetch,
    delay: float = 1.0,
    collected_at: str | None = None,
) -> tuple[list[dict], list[str]]:
    """(RawNotice 목록, 오류 목록). 한 공고의 실패가 나머지를 막지 않는다. 요청 사이에 delay초 쉰다."""
    raws, errors, seen = [], [], set()
    first = True

    def get(url: str) -> str:
        nonlocal first
        if not first and delay:
            time.sleep(delay)
        first = False
        return fetch(url)

    for page in range(1, pages + 1):
        try:
            rows = parse_list(get(list_url(board, page)))
        except Exception as e:  # 네트워크·파싱 실패는 기록하고 다음으로
            errors.append(f"list page {page}: {type(e).__name__}")
            continue
        for row in rows:
            if row.data_idx in seen:
                continue  # 고정 공지는 여러 페이지에 반복됨
            seen.add(row.data_idx)
            if max_items is not None and len(raws) >= max_items:
                return raws, errors
            url = view_url(board, row.bbs_mst_idx, row.data_idx)
            try:
                detail = parse_detail(get(url))
            except Exception as e:
                errors.append(f"{row.data_idx}: {type(e).__name__}")
                continue
            raws.append(to_raw_notice(board, row.data_idx, url, row, detail, collected_at or _now()))
    return raws, errors


def to_raw_notice(board: Board, data_idx: str, url: str, row, detail, collected_at: str) -> dict:
    posted = detail.posted_date or row.posted_date
    raw = {
        "schema_version": "1.0",
        "source_id": board.source_id,
        "source_notice_id": data_idx,
        "source_url": url,
        "title": detail.title or row.title,
        "body_text": detail.body_text,
        "published": (
            {"date": posted, "time": None, "timezone": None, "precision": "date", "evidence": f"날짜 {posted}"}
            if posted
            else None
        ),
        "collected_at": collected_at,
        "content_hash": "",
        "source_fields": {
            "posted_date": posted,
            "author_department": detail.author or row.author or None,
            "board_menu_idx": board.menu_idx,
            "bbs_mst_idx": row.bbs_mst_idx,
            "body_image_count": detail.body_image_count,
            # 대체텍스트로 내용을 읽은 이미지가 있을 때만 둔다 (그런 이미지가 없는 공고의 content_hash는 그대로)
            **({"body_image_text_count": detail.body_image_text_count} if detail.body_image_text_count else {}),
        },
        "attachments": [_attachment(name) for name in detail.attachments],
    }
    raw["content_hash"] = content_hash(raw)
    return raw
