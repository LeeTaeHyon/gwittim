"""콘테스트코리아(contestkorea.com) 대회·공모전 어댑터: 목록 → 새 공고만 상세 → RawNotice (D-038). DB 저장은 하지 않는다 (D-002).

- 목록은 사이트의 '대학생 대회공모전' 분류(Txt_code1 30·76)를 쓴다. 이 분류 안에도 청소년만 대상인 공고가 섞일 수 있어 대상 칸으로 다시 거른다.
- 목록의 대상 칸으로 먼저 거르고(미성년 대상만이면 상세를 열지 않음), 상세의 참가대상 칸으로 한 번 더 본다.
- 사이트가 접수 끝남(심사대기·발표 등)으로 표시한 공고는 상세를 열지 않는다.
- 원문 링크는 콘테스트코리아 상세 페이지다. 주최 측 공식 페이지는 따라가지 않고 주소만 source_fields.links에 남긴다(다음 PR).
- 목록의 접수 기간은 연도가 없어 쓰지 않는다. 날짜는 상세 상단 표의 글을 본문 첫머리에 '이름: 값' 줄로 옮겨 분석 단계가 읽는다.
- 상세의 사이트 자체 'AI 요약·분석'은 원문이 아니라서 본문에서 뺀다. 게시일이 없어 published는 null이다.
"""
from __future__ import annotations

import re
from collections.abc import Callable

from backend.collectors.common.external import CollectResult, ListDetailSource, collect_list_detail, mask_contacts

from .parser import Detail, ListRow, parse_detail, parse_list

SOURCE_ID = "contestkorea_contest"
BASE_URL = "https://www.contestkorea.com/sub/"

# 상단 표 항목 중 본문 첫머리에 옮기는 것 (이름은 사이트 표기 그대로). 접수하기·홈페이지는 주소라 source_fields.links로만 둔다
BODY_LABELS = ("주최 . 주관", "대표분야", "참가대상", "접수기간", "심사기간", "시상내역", "접수방법", "참가비용")


def list_url(page: int) -> str:
    return f"{BASE_URL}list.php?int_gbn=1&Txt_code1[0]=30&Txt_code1[1]=76&page={page}"


def detail_url(row: ListRow) -> str:
    return f"{BASE_URL}view.php?int_gbn=1&Txt_bcode={row.bcode}&str_no={row.str_no}"


def build(row: ListRow, html: str) -> tuple[str, str, dict]:
    d: Detail = parse_detail(html)
    lines = [
        f"{label.replace(' . ', '/')}: {re.sub(r'\s+,', ',', mask_contacts(d.info[label]))}" for label in BODY_LABELS if d.info.get(label)
    ]
    body = "\n".join(lines) + ("\n\n" + d.body_text if d.body_text else "")
    audience = d.info.get("참가대상") or row.audience or None
    if audience:
        audience = ", ".join(part.strip() for part in audience.split(",") if part.strip())
    fields = {
        "category_field": d.info.get("대표분야") or row.category or None,
        "audience": audience,
        "organizer": d.info.get("주최 . 주관") or row.host or None,
        "application_period": d.info.get("접수기간") or None,
        "prize": d.info.get("시상내역") or None,
        "links": d.links,
        "body_image_count": d.body_image_count,
    }
    return d.title or row.title, body, fields


SOURCE = ListDetailSource(
    source_id=SOURCE_ID,
    list_url=list_url,
    parse_list=parse_list,
    row_id=lambda row: row.str_no,
    row_ended=lambda row: row.ended,
    row_audience=lambda row: row.audience or None,
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
) -> CollectResult:
    return collect_list_detail(client, SOURCE, pages=pages, max_items=max_items, known=known, collected_at=collected_at)
