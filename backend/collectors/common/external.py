"""교외 출처 어댑터 공통 (D-038): RawNotice 조립, 연락처 가리기, 수집 결과, 이미 본 공고 기록."""
from __future__ import annotations

import json
import re
from html.parser import HTMLParser
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from .audience import audience_verdict
from .http_polite import FetchError, Stop
from .identity import content_hash

MAX_BODY_CHARS = 30_000  # 비정상적으로 긴 본문 방지

_EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
_PHONE = re.compile(r"(?<![\d-])(?:0\d{1,2}|1[5-9]\d{2})[-.\s]\d{3,4}(?:[-.\s]\d{4})?(?![\d-])")


def mask_contacts(text: str) -> str:
    """주최 측 담당자 이메일·전화번호는 수집하지 않는다 (mjc_www와 같은 원칙, source-review §2)."""
    return _PHONE.sub("[전화번호 생략]", _EMAIL.sub("[이메일 생략]", text))


def clean_text(text: str) -> str:
    return re.sub(r"[ \t ]+", " ", text).strip()


_BLOCK = {"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol"}


class _HtmlText(HTMLParser):
    """상세 본문 HTML → 줄 단위 글. 이미지는 개수만 센다."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.images = 0
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1
        elif tag == "img":
            self.images += 1
        elif tag in _BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = max(0, self._skip - 1)
        elif tag in _BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)


def html_to_text(fragment: str) -> tuple[str, int]:
    p = _HtmlText()
    p.feed(fragment or "")
    lines = [clean_text(line) for line in "".join(p.parts).splitlines()]
    return mask_contacts("\n".join(line for line in lines if line)), p.images


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def to_raw(
    *,
    source_id: str,
    notice_id: str,
    url: str,
    title: str,
    body_text: str,
    source_fields: dict,
    collected_at: str | None = None,
) -> dict:
    """RawNotice 조립. 교외 출처는 게시일이 없어 published는 null(미상)로 둔다 (SPEC §5 날짜 규칙)."""
    raw = {
        "schema_version": "1.0",
        "source_id": source_id,
        "source_notice_id": notice_id,
        "source_url": url,
        "title": title,
        "body_text": body_text[:MAX_BODY_CHARS],
        "published": None,
        "collected_at": collected_at or now_utc(),
        "content_hash": "",
        "source_fields": source_fields,
        "attachments": [],
    }
    raw["content_hash"] = content_hash(raw)
    return raw


@dataclass
class CollectResult:
    raws: list[dict] = field(default_factory=list)
    excluded: dict[str, str] = field(default_factory=dict)  # 공고 ID → 제외 이유 (대학생 대상 아님)
    errors: list[str] = field(default_factory=list)
    stopped: str | None = None  # 상한·멈춤으로 일찍 끝난 이유
    listed: int = 0  # 목록에서 본 행
    ended: int = 0  # 사이트가 접수 끝남으로 표시해 거른 행
    skipped_known: int = 0  # 이미 본 공고라 상세를 열지 않은 행
    parsed: int = 0  # 상세 파싱 성공
    pages_read: int = 0  # 읽은 목록 페이지 수


class SeenLog:
    """대학생 대상이 아니라 걸러 낸 공고를 기억한다. 안 그러면 매 실행 상세를 다시 열어 상한을 소진한다."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path else None
        self.excluded: dict[str, str] = {}
        if self.path and self.path.exists():
            self.excluded = json.loads(self.path.read_text(encoding="utf-8"))

    def has(self, key: str) -> bool:
        return key in self.excluded

    def add(self, key: str, reason: str) -> None:
        self.excluded[key] = reason

    def save(self) -> None:
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self.excluded, ensure_ascii=False, indent=1), encoding="utf-8")


BACKFILL_MAX_PAGES = 300  # 백필의 목록 페이지 안전 상한(사이트가 끝을 알리지 않을 때)


def _fetch_list(client, source, page: int) -> str:
    """목록 한 쪽을 받는다. 출처가 list_body(JSON POST)를 정의했으면 POST로 보낸다(씽굿)."""
    body = source.list_body(page) if source.list_body else None
    if body is None:
        return client.fetch(source.list_url(page), "list")
    key = "form_body" if source.list_form else "json_body"
    return client.fetch(source.list_url(page), "list", **{key: body})


@dataclass(frozen=True)
class ListDetailSource:
    """목록 → 새 공고만 상세 구조의 출처 하나. 어댑터가 사이트별 함수를 채운다."""

    source_id: str
    list_url: Callable[[int], str]
    parse_list: Callable[[str], list]
    row_id: Callable[[object], str]
    row_ended: Callable[[object], bool]  # 사이트가 접수 끝남으로 표시한 행
    row_audience: Callable[[object], str | None]  # 목록에 대상 칸이 있으면 그 글, 없으면 None
    detail_url: Callable[[object], str]
    # (행, 상세 HTML) → (제목, 본문, source_fields). source_fields["audience"]가 응모 대상 칸. 제목이 비면 파싱 실패
    build: Callable[[object, str], tuple[str, str, dict]]
    # 목록을 JSON POST로 받는 출처만: 쪽 번호 → 요청 본문. 없으면 GET
    list_body: Callable[[int], dict] | None = None
    list_form: bool = False  # list_body를 JSON이 아니라 폼(urlencoded)으로 보낸다(올콘)
    # 목록 응답에 본문까지 들어 있는 출처(씽굿): 상세 페이지를 따로 열지 않고 build(행, "")로 만든다
    detail_from_list: bool = False


def collect_list_detail(
    client,
    source: ListDetailSource,
    *,
    pages: int = 2,
    max_items: int | None = None,
    known: Callable[[str], bool] = lambda _id: False,
    collected_at: str | None = None,
    backfill: bool = False,
    max_pages: int = BACKFILL_MAX_PAGES,
) -> CollectResult:
    """목록 파싱 → 새 공고만 상세 요청 → RawNotice. max_items는 이번 실행의 상세 요청 상한.

    backfill(D-059, 수동 1회성 채우기): pages·max_items 상한 없이 목록을 끝까지 넘기며 접수 중인 공고를 모두 모은다.
    끝: 행이 0건인 페이지(2쪽부터), 이미 본 공고만 다시 나온 페이지(마지막 쪽 반복), 접수 끝난 행만 있는 페이지, max_pages.
    시간·요청 수 상한은 client(PoliteClient)가 지키고, 넘으면 Stop으로 거기서 끝낸다.

    한 공고의 실패가 나머지를 막지 않는다. client가 Stop(상한·429/403·robots.txt 읽기 실패)을 올리면 거기서 끝내고 사유를 남긴다.
    """
    result = CollectResult()
    seen: set[str] = set()
    details = 0
    at = collected_at or now_utc()
    page_limit = max_pages if backfill else pages
    for page in range(1, page_limit + 1):
        try:
            rows = source.parse_list(_fetch_list(client, source, page))
        except Stop as e:
            result.stopped = e.reason
            return result
        except FetchError as e:
            result.errors.append(f"list page {page}: {e}")
            continue
        result.pages_read += 1
        if not rows:
            if backfill and page > 1:
                break  # 목록 끝
            result.errors.append(f"list page {page}: 공고 행 0건 (구조 변경 의심)")
            continue
        fresh = [row for row in rows if source.row_id(row) not in seen]
        if backfill and not fresh:
            break  # 같은 페이지 반복: 마지막 쪽을 넘어섬
        if backfill and all(source.row_ended(row) for row in rows):
            result.ended += len(fresh)
            result.listed += len(fresh)
            seen.update(source.row_id(row) for row in fresh)
            break  # 접수 끝난 공고만 나오는 페이지
        for row in rows:
            nid = source.row_id(row)
            if nid in seen:
                continue
            seen.add(nid)
            result.listed += 1
            if source.row_ended(row):
                result.ended += 1
                continue
            if known(nid):
                result.skipped_known += 1
                continue
            audience = source.row_audience(row)
            if audience is not None and not (v := audience_verdict(audience)).include:
                result.excluded[nid] = v.reason
                continue
            if not backfill and max_items is not None and details >= max_items:
                result.stopped = f"상세 {max_items}건 상한(--max-items)"
                return result
            if source.detail_from_list:
                html = ""
            else:
                try:
                    html = client.fetch(source.detail_url(row), "detail")
                except Stop as e:
                    result.stopped = e.reason
                    return result
                except FetchError as e:
                    result.errors.append(f"{nid}: {e}")
                    continue
            details += 1
            try:
                title, body, fields = source.build(row, html)
            except Exception as e:  # 한 공고의 파싱 실패는 기록하고 다음으로
                result.errors.append(f"{nid}: 상세 파싱 {type(e).__name__}")
                continue
            if not title:
                result.errors.append(f"{nid}: 상세 파싱 실패 (제목 없음)")
                continue
            result.parsed += 1
            if not (v := audience_verdict(fields.get("audience"))).include:
                result.excluded[nid] = v.reason
                continue
            result.raws.append(
                to_raw(
                    source_id=source.source_id,
                    notice_id=nid,
                    url=source.detail_url(row),
                    title=title,
                    body_text=body,
                    source_fields=fields,
                    collected_at=at,
                )
            )
    return result
