"""올콘(all-con.co.kr) 대학생·일반인 공모전 목록·상세 파서. 표준 라이브러리만 쓴다.

목록: 페이지 스크립트(rumiPaging)가 부르는 공개 JSON 주소 POST /page/ajax.contest_list.php (폼 전송, t=1: 대학생·일반인 공모전).
      응답 rows[]: cl_srl 번호, cl_title(a 태그 글), cl_cate(배지), cl_status('접수중<br>D-3'), cl_date('26.11.09~26.11.29'), cl_host.
      목록 링크(/hit/...)는 조회수 집계용 이동 주소라 쓰지 않고 /view/contest/번호를 쓴다.
상세: /view/contest/번호 서버 렌더 HTML. h1 제목, 표(td.desc_host·desc_organizer·desc_date·desc_cate·desc_target·desc_award),
      a.cl_web 접수처 주소, div#contest_body 본문(유튜브 삽입 영역 제외). 날짜는 2자리 연도('26.11.09')라 20YY로 바꾼다.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from html.parser import HTMLParser

from backend.collectors.common.external import clean_text, mask_contacts

_BLOCK = {"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol"}
_TAG = re.compile(r"<[^>]+>")
_SHORT_DATE = re.compile(r"(?<!\d)(\d{2})\.(\d{2})\.(\d{2})(?!\d)")
_ENDED = re.compile(r"마감|종료")
LABELS = {
    "desc_host": "주최",
    "desc_organizer": "주관",
    "desc_date": "접수기간",
    "desc_cate": "분야",
    "desc_target": "응모대상",
    "desc_award": "시상내역",
}


def long_dates(text: str) -> str:
    """'26.11.09 ~ 26.11.30' → '2026-11-09 ~ 2026-11-30'."""
    return _SHORT_DATE.sub(lambda m: f"20{m[1]}-{m[2]}-{m[3]}", text)


@dataclass
class ListRow:
    id: str
    title: str
    status: str
    date: str

    @property
    def ended(self) -> bool:
        return bool(_ENDED.search(self.status))


def parse_list(text: str) -> list[ListRow]:
    try:
        data = json.loads(text)
    except ValueError:
        return []
    rows = []
    for r in data.get("rows") or []:
        if not r.get("cl_srl"):
            continue
        status = clean_text(_TAG.sub(" ", (r.get("cl_status") or "").replace("<br>", " ")))
        rows.append(ListRow(str(r["cl_srl"]), clean_text(_TAG.sub("", r.get("cl_title") or "")), status, r.get("cl_date") or ""))
    return rows


@dataclass
class Detail:
    title: str
    info: dict[str, str] = field(default_factory=dict)  # 표: 이름 → 값
    apply_url: str | None = None
    body_text: str = ""
    body_image_count: int = 0


class DetailParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title: list[str] = []
        self.info: dict[str, list[str]] = {}
        self.apply_url: str | None = None
        self.body: list[str] = []
        self.images = 0
        self._h1 = False
        self._td: str | None = None
        self._body_depth = 0
        self._skip_depth = 0  # 유튜브 삽입 영역
        self._script = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag in ("script", "style"):
            self._script += 1
            return
        if self._body_depth:
            if tag == "div":
                self._body_depth += 1
                if self._skip_depth or "main_youtube_wrap" in cls:
                    self._skip_depth += 1
            if self._skip_depth:
                return
            if tag == "img":
                self.images += 1
            elif tag in _BLOCK:
                self.body.append("\n")
            return
        if tag == "div" and a.get("id") == "contest_body":
            self._body_depth = 1
        elif tag == "h1" and not self.title:
            self._h1 = True
        elif tag == "td":
            self._td = next((c for c in cls if c in LABELS), None)
        elif tag == "a" and "cl_web" in cls and self.apply_url is None and (a.get("href") or "").startswith("http"):
            self.apply_url = a["href"]

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._script = max(0, self._script - 1)
            return
        if self._body_depth:
            if tag == "div":
                if self._skip_depth:
                    self._skip_depth -= 1
                self._body_depth -= 1
            elif tag in _BLOCK and not self._skip_depth:
                self.body.append("\n")
            return
        if tag == "h1":
            self._h1 = False
        elif tag == "td":
            self._td = None

    def handle_data(self, data):
        if self._script:
            return
        if self._body_depth:
            if not self._skip_depth:
                self.body.append(data)
        elif self._h1:
            self.title.append(data)
        elif self._td:
            self.info.setdefault(self._td, []).append(data)


def parse_detail(html: str) -> Detail:
    p = DetailParser()
    p.feed(html)
    lines = [clean_text(x) for x in "".join(p.body).splitlines()]
    return Detail(
        title=clean_text("".join(p.title)),
        info={LABELS[k]: clean_text("".join(v)) for k, v in p.info.items() if clean_text("".join(v))},
        apply_url=p.apply_url,
        body_text=mask_contacts("\n".join(x for x in lines if x)),
        body_image_count=p.images,
    )
