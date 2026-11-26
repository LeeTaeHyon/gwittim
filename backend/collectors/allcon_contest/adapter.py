"""올콘(all-con.co.kr) 대학생·일반인 공모전 어댑터: 목록 JSON(POST) → 새 공고만 상세 → RawNotice (D-038, D-059). DB 저장은 하지 않는다 (D-002).

- 목록은 사이트 스크립트가 부르는 공개 JSON 주소(/page/ajax.contest_list.php, robots 전체 허용)를 쓴다. 로그인·회원 영역은 열지 않는다.
- 접수 끝난 공고는 상세를 열지 않는다. 응모대상이 초·중·고·청소년뿐이면 제외한다(D-038).
- 접수처 주소는 따라가지 않고 source_fields.official_url에만 남긴다. 상세 본문의 연락처는 가린다.
- 분류: 규칙이 정하지 못한 공고(other)는 공모전으로 둔다(category_hint, D-059).
"""
from __future__ import annotations

from collections.abc import Callable

from backend.collectors.common.external import CollectResult, ListDetailSource, collect_list_detail, mask_contacts

from .parser import Detail, ListRow, long_dates, parse_detail, parse_list

SOURCE_ID = "allcon_contest"
BASE_URL = "https://www.all-con.co.kr/"
ROWS_PER_PAGE = 15  # 사이트 목록 화면과 같은 값
BODY_LABELS = ("분야", "응모대상", "주최", "주관", "접수기간", "시상내역")


def list_url(page: int) -> str:
    return BASE_URL + "page/ajax.contest_list.php"


def list_body(page: int) -> dict:
    # 사이트 rumiPaging의 요청과 같은 모양. t=1은 대학생·일반인 공모전 메뉴(/list/contest/1)
    return {"sortname": "cl_order", "sortorder": "asc", "page": str(page), "stx": "", "sfl": "", "rows": str(ROWS_PER_PAGE), "t": "1"}


def detail_url(row: ListRow) -> str:
    return f"{BASE_URL}view/contest/{row.id}"


def build(row: ListRow, html: str) -> tuple[str, str, dict]:
    d: Detail = parse_detail(html)
    info = {k: long_dates(v) for k, v in d.info.items()}
    lines = [f"{label}: {mask_contacts(info[label])}" for label in BODY_LABELS if info.get(label)]
    body = "\n".join(lines) + ("\n\n" + d.body_text if d.body_text else "")
    fields = {
        "category_field": info.get("분야") or None,
        "audience": info.get("응모대상") or None,
        "organizer": info.get("주최") or None,
        "application_period": info.get("접수기간") or None,
        "prize": info.get("시상내역") or None,
        "official_url": d.apply_url,
        "body_image_count": d.body_image_count,
        "category_hint": "contest",
        "category_hint_replaces": ["other"],
    }
    return d.title or row.title, body, fields


SOURCE = ListDetailSource(
    source_id=SOURCE_ID,
    list_url=list_url,
    parse_list=parse_list,
    row_id=lambda row: row.id,
    row_ended=lambda row: row.ended,
    row_audience=lambda row: None,
    detail_url=detail_url,
    build=build,
    list_body=list_body,
    list_form=True,
)


def collect(
    client,
    *,
    pages: int = 5,
    max_items: int | None = None,
    known: Callable[[str], bool] = lambda _id: False,
    collected_at: str | None = None,
    backfill: bool = False,
) -> CollectResult:
    return collect_list_detail(client, SOURCE, pages=pages, max_items=max_items, known=known, collected_at=collected_at, backfill=backfill)
