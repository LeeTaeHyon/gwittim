"""링커리어 공통 어댑터 부품: 메뉴(공모전·대외활동)별 ListDetailSource를 만든다 (D-038, D-059). DB 저장은 하지 않는다 (D-002).

- 원문 링크는 링커리어 상세 페이지다. 주최 측 홈페이지는 따라가지 않고 주소만 source_fields.official_url에 남긴다.
- 마감일이 지난 행은 상세를 열지 않는다. '충원 시 마감'(ASAP) 공고는 표시된 날짜를 마감으로 쓰지 않고 본문에 그렇게 적는다.
- 상단 정보(분야·대상·주최·접수 기간·혜택)는 구조화 필드에서 본문 첫머리 '이름: 값' 줄로 옮긴다.
- 담당자 이름·연락처는 읽지 않고, 본문 속 이메일·전화번호는 가린다.
"""
from __future__ import annotations

from collections.abc import Callable

from backend.collectors.common.external import CollectResult, ListDetailSource, collect_list_detail, mask_contacts

from .parser import Detail, ListRow, parse_detail, parse_list

BASE_URL = "https://linkareer.com/"
LIST_QUERY = "filterType=CATEGORY&orderBy_direction=DESC&orderBy_field=CREATED_AT"


def detail_url(row: ListRow) -> str:
    return f"{BASE_URL}activity/{row.id}"


def build_lines(d: Detail, *, contest: bool) -> list[str]:
    period = None
    if d.recruit_type == "ASAP":
        period = "충원 시 마감(마감일 미확정)"
    elif d.recruit_close:
        period = f"{d.recruit_start} ~ {d.recruit_close}" if d.recruit_start else f"~ {d.recruit_close}"
    activity = f"{d.activity_start or ''} ~ {d.activity_end or ''}".strip() if d.activity_start or d.activity_end else None
    prize = None
    if d.reward_man:
        prize = f"{d.reward_man:,}만원"
    items = [
        ("분야", ", ".join(d.categories)),
        ("응모대상" if contest else "모집대상", ", ".join(d.targets)),
        ("주최/주관", d.organizer),
        ("기관 유형", d.organization_type),
        ("접수기간", period),
        ("활동기간", activity),
        ("총 상금" if contest else "혜택", prize if contest else ", ".join(d.benefits)),
        ("모집인원", d.scale if not contest and d.scale and d.scale != "0" else None),
    ]
    return [f"{label}: {mask_contacts(value)}" for label, value in items if value]


def make_source(source_id: str, menu: str, type_id: int, *, contest: bool) -> ListDetailSource:
    # 분류 (D-059): 공모전 메뉴는 규칙이 못 정한 공고(other)를 공모전으로, 대외활동 메뉴는 본문 속 '대회' 같은 낱말로
    # 공모전이 되거나 못 정한 공고를 비교과·역량 프로그램(extracurricular, 사전의 가장 가까운 기존 코드)으로 둔다
    hint, replaces = ("contest", ["other"]) if contest else ("extracurricular", ["contest", "other"])

    def list_url(page: int) -> str:
        return f"{BASE_URL}list/{menu}?{LIST_QUERY}&page={page}"

    def build(row: ListRow, html: str) -> tuple[str, str, dict]:
        d = parse_detail(html, row.id)
        if d is None:
            return "", "", {}
        body = "\n".join(build_lines(d, contest=contest)) + ("\n\n" + d.body_text if d.body_text else "")
        fields = {
            "category_field": ", ".join(d.categories) or None,
            "audience": ", ".join(d.targets) or None,
            "organizer": d.organizer or None,
            "application_period": f"{d.recruit_start} ~ {d.recruit_close}" if d.recruit_close and d.recruit_type != "ASAP" else None,
            "recruit_type": d.recruit_type,
            "official_url": d.homepage,
            "apply_url": d.apply_url,
            "body_image_count": d.body_image_count,
            "category_hint": hint,
            "category_hint_replaces": replaces,
        }
        return d.title or row.title, body, fields

    return ListDetailSource(
        source_id=source_id,
        list_url=list_url,
        parse_list=lambda html: parse_list(html, type_id=type_id),
        row_id=lambda row: row.id,
        row_ended=lambda row: row.ended,
        row_audience=lambda row: None,  # 목록에 대상 칸이 없어 상세의 대상으로 판단한다
        detail_url=detail_url,
        build=build,
    )


def make_collect(source: ListDetailSource) -> Callable[..., CollectResult]:
    def collect(client, *, pages: int = 2, max_items: int | None = None, known: Callable[[str], bool] = lambda _id: False,
                collected_at: str | None = None, backfill: bool = False) -> CollectResult:
        return collect_list_detail(client, source, pages=pages, max_items=max_items, known=known, collected_at=collected_at, backfill=backfill)

    return collect
