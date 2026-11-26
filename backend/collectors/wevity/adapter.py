"""위비티(wevity.com) 공모전 어댑터: 목록 → 새 공고만 상세 → RawNotice (D-038). DB 저장은 하지 않는다 (D-002).

- 원문 링크는 위비티 상세 페이지다. 주최 측 공식 페이지는 따라가지 않고 주소만 source_fields.official_url에 남긴다(다음 PR).
- 목록에서 사이트가 '마감'으로 표시한 공고는 상세를 열지 않는다.
- 위비티에는 게시일이 없어 published는 null이다. 접수 기간은 상세 상단 표의 글을 본문 첫머리에 '이름: 값' 줄로 옮겨 분석 단계가 읽는다.
"""
from __future__ import annotations

from collections.abc import Callable

from backend.collectors.common.external import CollectResult, ListDetailSource, collect_list_detail, mask_contacts

from .parser import Detail, ListRow, parse_detail, parse_list

SOURCE_ID = "wevity_contest"
BASE_URL = "https://www.wevity.com/"

# 본문 첫머리에 옮기는 상단 표 항목. 홈페이지·첨부파일은 주소·상태라 본문에 넣지 않는다
BODY_LABELS = ("분야", "응모대상", "주최/주관", "후원/협찬", "접수기간", "총 상금", "1등 상금", "시상내역")


def list_url(page: int) -> str:
    return f"{BASE_URL}?c=find&s=1&gub=1&gp={page}"


def detail_url(row: ListRow) -> str:
    return f"{BASE_URL}?c=find&s=1&gub=1&gbn=viewok&ix={row.ix}"


def build(row: ListRow, html: str) -> tuple[str, str, dict]:
    d: Detail = parse_detail(html)
    lines = [f"{label}: {mask_contacts(d.info[label])}" for label in BODY_LABELS if d.info.get(label)]
    body = "\n".join(lines) + ("\n\n" + d.body_text if d.body_text else "")
    fields = {
        "category_field": d.info.get("분야") or row.fields or None,
        "audience": d.info.get("응모대상") or None,
        "organizer": d.info.get("주최/주관") or row.organizer or None,
        "application_period": d.info.get("접수기간") or None,
        "prize_total": d.info.get("총 상금") or None,
        "prize_first": d.info.get("1등 상금") or None,
        "official_url": d.homepage,
        "body_image_count": d.body_image_count,
    }
    return d.title or row.title, body, fields


SOURCE = ListDetailSource(
    source_id=SOURCE_ID,
    list_url=list_url,
    parse_list=parse_list,
    row_id=lambda row: row.ix,
    row_ended=lambda row: row.ended,
    row_audience=lambda row: None,  # 목록에 대상 칸이 없어 상세의 응모대상으로 판단한다
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
