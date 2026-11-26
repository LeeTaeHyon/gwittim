"""씽굿(thinkcontest.com) 공모전 어댑터: 목록 JSON(POST) → RawNotice (D-038, D-059). DB 저장은 하지 않는다 (D-002).

- 목록 응답에 본문이 들어 있어 상세 페이지를 열지 않는다(요청 수가 적다).
- 원문 링크는 씽굿 상세 페이지다. 주최 측 홈페이지 주소(hompage_url)는 따라가지 않고 source_fields.official_url에만 남긴다.
- 마감(END) 공고는 만들지 않는다. 대상 칸이 초·중·고·청소년뿐이면 제외한다(D-038).
- 담당자 이름·연락처·이메일은 읽지 않고 본문 속 연락처는 가린다.
- 분류: 규칙이 정하지 못한 공고(other)는 공모전으로 둔다(category_hint, D-059).
"""
from __future__ import annotations

from collections.abc import Callable

from backend.collectors.common.external import (
    CollectResult,
    ListDetailSource,
    clean_text,
    collect_list_detail,
    html_to_text,
    mask_contacts,
)

from .parser import ListRow, parse_list

SOURCE_ID = "thinkgood_contest"
BASE_URL = "https://www.thinkcontest.com/thinkgood/user/contest/"
RECORDS_PER_PAGE = 10  # 서버가 정하는 값(요청해도 10건)


def list_url(page: int) -> str:
    return BASE_URL + "subList.do"


def list_body(page: int) -> dict:
    # 사이트 contest.js의 목록 요청과 같은 모양(검색 조건은 모두 비움)
    return {
        "recordsPerPage": RECORDS_PER_PAGE,
        "currentPageNo": page,
        "contest_field": "",
        "host_organ": "",
        "enter_qualified": "",
        "award_size": "",
        "searchStatus": "Y",
    }


def detail_url(row: ListRow) -> str:
    return f"{BASE_URL}view.do?contest_pk={row.pk}"


def _text(item: dict, key: str) -> str:
    return clean_text((item.get(key) or "").replace("\ufeff", ""))


def build(row: ListRow, _html: str) -> tuple[str, str, dict]:
    it = row.item
    organizer = _text(it, "host_company")
    prize = " ".join(x for x in (_text(it, "award_type_nm"), _text(it, "prize_money")) if x) or None
    items = [
        ("분야", _text(it, "contest_field_nm")),
        ("응모대상", row.audience),
        ("주최/주관", organizer),
        ("접수기간", _text(it, "receive_period")),
        ("시상내역", prize),
        ("접수방법", _text(it, "apply_method_nm")),
    ]
    lines = [f"{label}: {mask_contacts(value)}" for label, value in items if value]
    body_text, images = html_to_text(it.get("competition_syllabus") or "")
    body = "\n".join(lines) + ("\n\n" + body_text if body_text else "")
    fields = {
        "category_field": _text(it, "contest_field_nm") or None,
        "audience": row.audience or None,
        "organizer": organizer or None,
        "application_period": _text(it, "receive_period") or None,
        "prize": prize,
        "official_url": _text(it, "hompage_url") or None,
        "body_image_count": images,
        "category_hint": "contest",
        "category_hint_replaces": ["other"],
    }
    return _text(it, "program_nm"), body, fields


SOURCE = ListDetailSource(
    source_id=SOURCE_ID,
    list_url=list_url,
    parse_list=parse_list,
    row_id=lambda row: row.pk,
    row_ended=lambda row: row.ended,
    row_audience=lambda row: row.audience or None,
    detail_url=detail_url,
    build=build,
    list_body=list_body,
    detail_from_list=True,
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
