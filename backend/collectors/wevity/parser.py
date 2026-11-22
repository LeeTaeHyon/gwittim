"""위비티(wevity.com) 공모전 목록·상세 HTML 파서. 표준 라이브러리 html.parser만 쓴다.

목록: ul.list > li, 제목 div.tit a(...&ix=번호), 분야 div.sub-tit, 주최 div.organ, 상태 div.day span.dday(ing·soon·future·end).
상세: div.tit-area h6.tit 제목, ul.cd-info-list > li(span.tit 이름 + 값), div#viewContents 본문.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from html.parser import HTMLParser

from backend.collectors.common.external import clean_text, mask_contacts

_IX = re.compile(r"[?&]ix=(\d+)")
_BLOCK = {"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol"}
_ENDED_TEXT = re.compile(r"^(?:접수\s*)?(?:마감|종료)$|마감됨|종료됨")


@dataclass
class ListRow:
    ix: str
    title: str
    fields: str  # '분야 :' 뒤의 글
    organizer: str
    status_class: str  # ing | soon | future | end ...
    status_text: str

    @property
    def ended(self) -> bool:
        """사이트가 접수 끝남으로 표시한 행. '마감임박'(soon)은 아직 접수 중이다."""
        return "end" in self.status_class.split() or bool(_ENDED_TEXT.search(self.status_text.strip()))


@dataclass
class Detail:
    title: str
    info: dict[str, str] = field(default_factory=dict)  # 상단 표: 이름 → 값
    homepage: str | None = None
    body_text: str = ""
    body_image_count: int = 0


class ListParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[ListRow] = []
        self._row: dict | None = None
        self._ul_depth = 0  # 본문 목록 ul.list 안에서만 읽는다 (배너·사이드의 같은 공고 링크 제외)
        self._cell: str | None = None  # 지금 글을 모으는 칸: sub-tit | organ | day
        self._cell_depth = 0
        self._in_a = False
        self._a_span = 0  # a 안의 span(SPECIAL 같은 표시)은 제목이 아니다
        self._status = False
        self._buf: list[str] = []
        self._status_buf: list[str] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag == "ul":
            if self._ul_depth:
                self._ul_depth += 1
            elif "list" in cls:
                self._ul_depth = 1
            return
        if tag == "li" and self._ul_depth:
            self._row = {"ix": None, "title": [], "sub-tit": "", "organ": "", "day": "", "status_class": "", "status_text": ""}
            return
        if self._row is None:
            return
        if tag == "a" and self._row["ix"] is None and (m := _IX.search(a.get("href") or "")):
            self._row["ix"], self._in_a = m[1], True
        elif tag == "span" and self._in_a:
            self._a_span += 1
        elif tag == "span" and "dday" in cls and self._cell == "day":
            self._row["status_class"] = " ".join(c for c in cls if c != "dday")
            self._status, self._status_buf = True, []
        elif tag == "div":
            if self._cell:
                self._cell_depth += 1
            else:
                for name in ("sub-tit", "organ", "day"):
                    if name in cls:
                        self._cell, self._cell_depth, self._buf = name, 1, []

    def handle_endtag(self, tag):
        if tag == "ul" and self._ul_depth:
            self._ul_depth -= 1
            return
        if self._row is None:
            return
        if tag == "span" and self._in_a and self._a_span:
            self._a_span -= 1
        elif tag == "span" and self._status:
            self._status = False
            self._row["status_text"] = clean_text("".join(self._status_buf))
        elif tag == "a" and self._in_a:
            self._in_a = False
        elif tag == "div" and self._cell:
            self._cell_depth -= 1
            if self._cell_depth == 0:
                self._row[self._cell] = clean_text("".join(self._buf))
                self._cell = None
        elif tag == "li":
            row, self._row = self._row, None
            if row["ix"]:
                fields = re.sub(r"^분야\s*:\s*", "", row["sub-tit"])
                title = clean_text("".join(row["title"]))
                self.rows.append(ListRow(row["ix"], title, fields, row["organ"], row["status_class"], row["status_text"]))

    def handle_data(self, data):
        if self._row is None:
            return
        if self._status:
            self._status_buf.append(data)
        elif self._in_a:
            if not self._a_span:
                self._row["title"].append(data)
        elif self._cell and self._cell != "day":
            self._buf.append(data)


class DetailParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.info: dict[str, str] = {}
        self.homepage: str | None = None
        self.body_parts: list[str] = []
        self.images = 0
        self._in_titarea = False
        self._in_title = False
        self._in_info = False
        self._li: dict | None = None
        self._label: list[str] | None = None
        self._body_depth = 0
        self._skip = 0  # script/style, 날짜 옆 D-day 표시

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag in ("script", "style"):
            self._skip += 1
            return
        if self._body_depth:
            if tag == "div":
                self._body_depth += 1
            if tag in _BLOCK:
                self.body_parts.append("\n")
            elif tag == "img":
                self.images += 1
            return
        if tag == "div" and a.get("id") == "viewContents":
            self._body_depth = 1
        elif tag == "div" and "tit-area" in cls:
            self._in_titarea = True
        elif tag == "h6" and "tit" in cls and self._in_titarea:
            self._in_title = True
        elif tag == "ul" and "cd-info-list" in cls:
            self._in_info = True
        elif tag == "li" and self._in_info:
            self._li = {"label": "", "value": [], "href": None, "skip": "sns" in cls}
        elif self._li is not None:
            if tag == "span" and "tit" in cls:
                self._label = []
            elif tag == "span" and "cil-dday" in cls:
                self._skip += 1
            elif tag == "a" and (a.get("href") or "").startswith("http") and self._li["href"] is None:
                self._li["href"] = a["href"]

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = max(0, self._skip - 1)
            return
        if self._body_depth:
            if tag == "div":
                self._body_depth -= 1
            elif tag in _BLOCK:
                self.body_parts.append("\n")
            return
        if tag == "h6" and self._in_title:
            self._in_title = self._in_titarea = False
        elif tag == "ul" and self._in_info:
            self._in_info = False
        elif self._li is not None:
            if tag == "span" and self._label is not None:
                self._li["label"] = clean_text("".join(self._label))
                self._label = None
            elif tag == "span" and self._skip:
                self._skip -= 1
            elif tag == "li":
                li, self._li = self._li, None
                if li["label"] and not li["skip"]:
                    self.info.setdefault(li["label"], clean_text("".join(li["value"])))
                    if li["label"] == "홈페이지" and li["href"] and self.homepage is None:
                        self.homepage = li["href"]

    def handle_data(self, data):
        if self._skip:
            return
        if self._body_depth:
            self.body_parts.append(data)
        elif self._in_title:
            self.title_parts.append(data)
        elif self._li is not None:
            (self._label if self._label is not None else self._li["value"]).append(data)


def parse_list(html: str) -> list[ListRow]:
    p = ListParser()
    p.feed(html)
    return p.rows


def parse_detail(html: str) -> Detail:
    p = DetailParser()
    p.feed(html)
    lines = [clean_text(line) for line in "".join(p.body_parts).splitlines()]
    body = mask_contacts("\n".join(line for line in lines if line))
    return Detail(
        title=clean_text("".join(p.title_parts)),
        info=p.info,
        homepage=p.homepage,
        body_text=body,
        body_image_count=p.images,
    )
