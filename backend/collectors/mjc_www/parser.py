"""명지전문대 www 게시판(list.do / view.do) HTML 파서. 표준 라이브러리 html.parser만 쓴다."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from html.parser import HTMLParser

_VIEW = re.compile(r"fn_view\('(?P<mst>BM\d+)'\s*,\s*'(?P<data>BD\d+)'")
_DOWN = re.compile(r"fn_egov_downFile\('BM\d+'\s*,\s*'BD\d+'\s*,\s*'(?P<file>BF\d+)'\)")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_BLOCK = {"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "table", "ul", "ol"}
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")


@dataclass
class ListRow:
    bbs_mst_idx: str
    data_idx: str
    title: str
    author: str
    posted_date: str | None
    pinned: bool


@dataclass
class Detail:
    title: str
    author: str | None
    posted_date: str | None
    attachments: list[str] = field(default_factory=list)
    body_text: str = ""
    body_image_count: int = 0


def _clean(text: str) -> str:
    return re.sub(r"[ \t ]+", " ", text).strip()


class ListParser(HTMLParser):
    """게시판 표(tbody)의 행에서 fn_view 링크가 있는 행만 읽는다."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[ListRow] = []
        self._row: dict | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "tr":
            self._row = {"cells": [], "pinned": "cell_notice" in (a.get("class") or ""), "view": None}
        elif tag == "td" and self._row is not None:
            self._cell = []
        elif tag == "a" and self._row is not None and (m := _VIEW.search(a.get("href") or "")):
            self._row["view"] = m

    def handle_endtag(self, tag):
        if tag == "td" and self._row is not None and self._cell is not None:
            self._row["cells"].append(_clean("".join(self._cell)))
            self._cell = None
        elif tag == "tr" and self._row is not None:
            row, self._row = self._row, None
            if row["view"] and len(row["cells"]) >= 5:
                cells = row["cells"]
                date = next((c for c in cells if _DATE.match(c)), None)
                self.rows.append(
                    ListRow(row["view"]["mst"], row["view"]["data"], cells[1], cells[3], date, row["pinned"])
                )

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)


class DetailParser(HTMLParser):
    """view.do: div.board_view의 제목·작성자·날짜·첨부와 div#divMemo 본문."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.fields: dict[str, str] = {}
        self.attachments: list[str] = []
        self.body_parts: list[str] = []
        self.images = 0
        self._in_title = False
        self._th: list[str] | None = None
        self._last_th: str | None = None
        self._td: list[str] | None = None
        self._attach: list[str] | None = None
        self._memo_depth = 0
        self._skip = 0  # script/style

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("script", "style"):
            self._skip += 1
            return
        if self._memo_depth:
            if tag == "div":
                self._memo_depth += 1
            if tag in _BLOCK:
                self.body_parts.append("\n")
            elif tag == "td":
                self.body_parts.append("\t")
            elif tag == "img":
                self.images += 1
            return
        if tag == "div" and a.get("id") == "divMemo":
            self._memo_depth = 1
        elif tag == "h2" and "tit" in (a.get("class") or "").split():
            self._in_title = True
        elif tag == "th":
            self._th = []
        elif tag == "td" and self._last_th:
            self._td = []
        elif tag == "a" and _DOWN.search(a.get("href") or ""):
            self._attach = []

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = max(0, self._skip - 1)
            return
        if self._memo_depth:
            if tag == "div":
                self._memo_depth -= 1
            elif tag in _BLOCK:
                self.body_parts.append("\n")
            return
        if tag == "h2" and self._in_title:
            self._in_title = False
        elif tag == "th" and self._th is not None:
            self._last_th, self._th = _clean("".join(self._th)), None
        elif tag == "td" and self._td is not None:
            self.fields.setdefault(self._last_th, _clean("".join(self._td)))
            self._td, self._last_th = None, None
        elif tag == "a" and self._attach is not None:
            name = _clean("".join(self._attach))
            if name:
                self.attachments.append(name)
            self._attach = None

    def handle_data(self, data):
        if self._skip:
            return
        if self._memo_depth:
            self.body_parts.append(data)
        elif self._in_title:
            self.title_parts.append(data)
        elif self._attach is not None:
            self._attach.append(data)
        elif self._th is not None:
            self._th.append(data)
        elif self._td is not None:
            self._td.append(data)

    def handle_comment(self, data):
        pass  # 주석 안의 예전 마크업은 무시


def parse_list(html: str) -> list[ListRow]:
    p = ListParser()
    p.feed(html)
    return p.rows


def parse_detail(html: str) -> Detail:
    p = DetailParser()
    p.feed(html)
    lines = [_clean(line) for line in "".join(p.body_parts).splitlines()]
    body = "\n".join(line for line in lines if line)
    body = _EMAIL.sub("[이메일 생략]", body)  # 이메일 무단수집 거부 고지 (source-review §2)
    date = p.fields.get("날짜")
    return Detail(
        title=_clean("".join(p.title_parts)),
        author=p.fields.get("작성자") or None,
        posted_date=date if date and _DATE.match(date) else None,
        attachments=p.attachments,
        body_text=body,
        body_image_count=p.images,
    )
