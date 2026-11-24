"""숭의여자대학교 공지사항 어댑터: 목록 → 새 공고만 상세 → RawNotice (D-045). DB 저장은 하지 않는다 (D-002).

- 게시판은 공지사항 1개. 분류(공통·교무학사·장학대출 등)와 작성 부서는 source_fields에 둔다.
- 본문 이미지(/_attach/)는 robots가 막아 요청하지 않는다. 포스터 이미지에만 있는 내용은 본문이 짧은 채로 두고 원문 링크로 안내한다.
- 첨부 파일은 ?mode=download 링크(robots 허용)의 이름·주소만 남기고 내려받지는 않는다.
- 등록일은 날짜만 있어 published는 precision=date. 시각 없는 날짜에는 시간대를 붙이지 않는다 (SPEC §5).
- 학교 출처 공지라 대학생 대상 거르기(audience)는 하지 않는다. 공개 범위는 추천의 학교 규칙이 정한다.
"""
from __future__ import annotations

import re
from collections.abc import Callable
from urllib.parse import urljoin

from backend.collectors.common.external import CollectResult, now_utc
from backend.collectors.common.http_polite import FetchError, Stop
from backend.collectors.common.identity import content_hash

from .parser import Detail, ListRow, parse_detail, parse_list

SOURCE_ID = "sewu_www_notice"
BOARD_URL = "https://www.sewu.ac.kr/sewu/news/notice.do"
PAGE_SIZE = 10
MAX_BODY_CHARS = 30_000  # 비정상적으로 긴 본문 방지 (external.MAX_BODY_CHARS와 같은 값)

_EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")


def list_url(page: int) -> str:
    return f"{BOARD_URL}?mode=list&articleLimit={PAGE_SIZE}&article.offset={(page - 1) * PAGE_SIZE}"


def detail_url(row: ListRow) -> str:
    return f"{BOARD_URL}?mode=view&articleNo={row.article_no}"


def _attachment(name: str, href: str) -> dict:
    suffix = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    url = urljoin(BOARD_URL, href)  # href는 '?mode=download&articleNo=&attachNo=' 형태의 상대 주소
    return {"file_name": name, "url": url, "type": suffix[:10] or None}


def to_raw_notice(row: ListRow, detail: Detail, collected_at: str) -> dict:
    posted = detail.posted_date or row.posted_date
    body = _EMAIL.sub("[이메일 생략]", detail.body_text)  # 이메일 무단수집 거부 고지 (source-review §2)
    raw = {
        "schema_version": "1.0",
        "source_id": SOURCE_ID,
        "source_notice_id": row.article_no,
        "source_url": detail_url(row),
        "title": detail.title or row.title,
        "body_text": body[:MAX_BODY_CHARS],
        "published": (
            {"date": posted, "time": None, "timezone": None, "precision": "date", "evidence": f"등록일 {posted}"}
            if posted
            else None
        ),
        "collected_at": collected_at,
        "content_hash": "",
        "source_fields": {
            "posted_date": posted,
            "board_category": row.category,
            "author_department": detail.department or row.department,
            "pinned": row.pinned,
            "body_image_count": detail.body_image_count,
        },
        "attachments": [_attachment(n, h) for n, h in detail.attachments],
    }
    raw["content_hash"] = content_hash(raw)
    return raw


def collect(
    client,
    *,
    pages: int = 2,
    max_items: int | None = None,
    known: Callable[[str], bool] = lambda _id: False,
    collected_at: str | None = None,
) -> CollectResult:
    """목록 파싱 → 새 공고만 상세 요청 → RawNotice. max_items는 이번 실행의 상세 요청 상한.

    한 공고의 실패가 나머지를 막지 않는다. client가 Stop(상한·429/403·robots.txt 읽기 실패)을 올리면 거기서 끝낸다.
    고정 공지는 모든 페이지에 반복되므로 공고 번호로 한 번만 본다.
    """
    result = CollectResult()
    seen: set[str] = set()
    details = 0
    at = collected_at or now_utc()
    for page in range(1, pages + 1):
        try:
            rows = parse_list(client.fetch(list_url(page), "list"))
        except Stop as e:
            result.stopped = e.reason
            return result
        except FetchError as e:
            result.errors.append(f"list page {page}: {e}")
            continue
        if not rows:
            result.errors.append(f"list page {page}: 공고 행 0건 (구조 변경 의심)")
            continue
        for row in rows:
            if row.article_no in seen:
                continue
            seen.add(row.article_no)
            result.listed += 1
            if known(row.article_no):
                result.skipped_known += 1
                continue
            if max_items is not None and details >= max_items:
                result.stopped = f"상세 {max_items}건 상한(--max-items)"
                return result
            try:
                html = client.fetch(detail_url(row), "detail")
            except Stop as e:
                result.stopped = e.reason
                return result
            except FetchError as e:
                result.errors.append(f"{row.article_no}: {e}")
                continue
            details += 1
            try:
                detail = parse_detail(html)
                if not (detail.title or row.title):
                    raise ValueError("제목 없음")
                raw = to_raw_notice(row, detail, at)
            except Exception as e:  # 한 공고의 파싱 실패는 기록하고 다음으로
                result.errors.append(f"{row.article_no}: 상세 파싱 {type(e).__name__}")
                continue
            result.parsed += 1
            result.raws.append(raw)
    return result

