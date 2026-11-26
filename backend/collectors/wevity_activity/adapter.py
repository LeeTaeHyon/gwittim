"""위비티 대외활동(wevity.com ?c=active) 어댑터: 목록 → 새 공고만 상세 → RawNotice (D-038, D-059). DB 저장은 하지 않는다 (D-002).

- 상세 구조는 공모전 메뉴와 같아 wevity 파서·조립을 재사용하고, 라벨만 대외활동에 맞게 바꾼다('총 상금' → '혜택').
- 같은 공고가 공모전 메뉴에도 올라오는 일이 있어 중복 묶기(D-048)에서 위비티 공모전 쪽을 남긴다.
- 분류: 대외활동 메뉴는 규칙이 공모전·기타로 정한 공고를 비교과·역량 프로그램(extracurricular)으로 둔다 (D-059).
"""
from __future__ import annotations

from collections.abc import Callable

from backend.collectors.common.external import CollectResult, ListDetailSource, collect_list_detail, mask_contacts
from backend.collectors.wevity.parser import Detail, parse_detail

from .parser import ListRow, parse_list

SOURCE_ID = "wevity_activity"
BASE_URL = "https://www.wevity.com/"
BODY_LABELS = ("분야", "응모대상", "주최/주관", "후원/협찬", "접수기간", "총 상금")
_RELABEL = {"총 상금": "혜택"}


def list_url(page: int) -> str:
    return f"{BASE_URL}?c=active&s=1&gp={page}"


def detail_url(row: ListRow) -> str:
    return f"{BASE_URL}?c=active&s=1&gbn=viewok&ix={row.ix}"


def build(row: ListRow, html: str) -> tuple[str, str, dict]:
    d: Detail = parse_detail(html)
    lines = [f"{_RELABEL.get(label, label)}: {mask_contacts(d.info[label])}" for label in BODY_LABELS if d.info.get(label)]
    body = "\n".join(lines) + ("\n\n" + d.body_text if d.body_text else "")
    fields = {
        "category_field": d.info.get("분야") or row.fields or None,
        "audience": d.info.get("응모대상") or None,
        "organizer": d.info.get("주최/주관") or None,
        "application_period": d.info.get("접수기간") or None,
        "benefit": d.info.get("총 상금") or None,
        "official_url": d.homepage,
        "body_image_count": d.body_image_count,
        "category_hint": "extracurricular",
        "category_hint_replaces": ["contest", "other"],
    }
    return d.title or row.title, body, fields


SOURCE = ListDetailSource(
    source_id=SOURCE_ID,
    list_url=list_url,
    parse_list=parse_list,
    row_id=lambda row: row.ix,
    row_ended=lambda row: row.ended,
    row_audience=lambda row: None,
    detail_url=detail_url,
    build=build,
)


def collect(
    client,
    *,
    pages: int = 2,
    max_items: int | None = None,
    known: Callable[[str], bool] = lambda _id: False,
    collected_at: str | None = None,
    backfill: bool = False,
) -> CollectResult:
    return collect_list_detail(client, SOURCE, pages=pages, max_items=max_items, known=known, collected_at=collected_at, backfill=backfill)
