"""숭의여대 공지사항(notice.do) HTML 파서. 표준 라이브러리 html.parser만 쓴다.

- 목록: 표(tbody)의 행. 열은 NO·분류·제목·작성자(부서)·등록일·조회수·첨부. 고정 공지 행(b-cate-notice)은 매 페이지에 반복된다.
- 상세: 제목·작성자(부서)·등록일·첨부 링크(?mode=download)와 본문 div.fr-view.
- 본문 이미지(/_attach/, robots가 막음)는 요청하지 않는다. 개수만 센다.
- 조회수·IP 같은 칸은 읽지 않는다(바뀌는 값이거나 개인정보라 저장하지 않음).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlsplit

_DATE = re.compile(r"^(\d{4})\.(\d{2})\.(\d{2})$")
_BLOCK = {"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "table", "ul", "ol"}


@dataclass
class ListRow:
    article_no: str
    title: str
    category: str | None
    department: str | None
    posted_date: str | None
    pinned: bool


@dataclass
class Detail:
    title: str
    department: str | None
    posted_date: str | None
    attachments: list[tuple[str, str]] = field(default_factory=list)  # (파일 이름, 상대 링크)
    body_text: str = ""
    body_image_count: int = 0


def _clean(text: str) -> str:
    return re.sub(r"[ \t\xa0​]+", " ", text).strip()


def _date(text: str | None) -> str | None:
    m = _DATE.match(_clean(text or ""))
    return f"{m[1]}-{m[2]}-{m[3]}" if m else None


def _article_no(href: str) -> str | None:
    no = parse_qs(urlsplit(href).query).get("articleNo", [None])[0]
    return no if no and no.isdigit() else None


class ListParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[ListRow] = []
        self._row: dict | None = None
        self._cell: list[str] | None = None
        self._title: list[str] | None = None
        self._title_span = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag == "tr":
            self._row = {"cells": [], "pinned": "b-cate-notice" in cls, "no": None, "title": ""}
        elif self._row is None:
            return
        elif tag == "td" and self._cell is None:
            self._cell = []
        elif tag == "a" and "b-title" in cls and self._row["no"] is None:
            self._row["no"] = a.get("data-article-no") or _article_no(a.get("href") or "")
            self._title = []
        elif tag == "span" and self._title is not None:
            self._title_span += 1  # '[공지]' 표시는 제목이 아니다

    def handle_endtag(self, tag):
        if self._row is None:
            return
        if tag == "span" and self._title_span:
            self._title_span -= 1
        elif tag == "a" and self._title is not None:
            self._row["title"] = _clean(" ".join(x.strip() for x in self._title if x.strip()))
            self._title = None
        elif tag == "td" and self._cell is not None:
            self._row["cells"].append(_clean(" ".join(x.strip() for x in self._cell if x.strip())))
            self._cell = None
        elif tag == "tr":
            row, self._row = self._row, None
            c = row["cells"]
            if row["no"] and row["no"].isdigit() and row["title"] and len(c) >= 5:
                self.rows.append(
                    ListRow(row["no"], row["title"], c[1] or None, c[3] or None, _date(c[4]), row["pinned"])
                )

    def handle_data(self, data):
        if self._title is not None and not self._title_span:
            self._title.append(data)
        if self._cell is not None:
            self._cell.append(data)


class DetailParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.writer: list[str] = []
        self.date: list[str] = []
        self.attachments: list[tuple[str, str]] = []
        self.body_parts: list[str] = []
        self.images = 0
        self._in_top = False  # div.b-title-box 안의 span이 제목
        self._title_span = False
        self._li: str | None = None  # b-writer-box | b-date-box
        self._attach: tuple[list[str], str] | None = None
        self._body_depth = 0
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag in ("script", "style"):
            self._skip += 1
            return
        if self._body_depth:
            if tag == "div":
                self._body_depth += 1
            elif tag == "img":
                self.images += 1
            if tag in _BLOCK:
                self.body_parts.append("\n")
            elif tag in ("td", "th"):
                self.body_parts.append("\t")
            return
        if tag == "div" and "fr-view" in cls:
            self._body_depth = 1
        elif tag == "div" and "b-title-box" in cls:
            self._in_top = True
        elif tag == "span" and self._in_top:
            self._title_span = True
        elif tag == "li" and ("b-writer-box" in cls or "b-date-box" in cls):
            self._li = "b-writer-box" if "b-writer-box" in cls else "b-date-box"
        elif tag == "a" and "file-down-btn" in cls and "mode=download" in (a.get("href") or ""):
            self._attach = ([], a["href"])

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
        if tag == "span" and self._title_span:
            self._title_span = False
        elif tag == "div" and self._in_top:
            self._in_top = False
        elif tag == "li" and self._li:
            self._li = None
        elif tag == "a" and self._attach is not None:
            name = _clean("".join(self._attach[0]))
            if name:
                self.attachments.append((name, self._attach[1]))
            self._attach = None

    def handle_data(self, data):
        if self._skip:
            return
        if self._body_depth:
            self.body_parts.append(data)
        elif self._title_span:
            self.title_parts.append(data)
        elif self._attach is not None:
            self._attach[0].append(data)
        elif self._li == "b-writer-box":
            self.writer.append(data)
        elif self._li == "b-date-box":
            self.date.append(data)


def parse_list(html: str) -> list[ListRow]:
    p = ListParser()
    p.feed(html)
    return p.rows


def _joined(parts: list[str]) -> str:
    return _clean(" ".join(x.strip() for x in parts if x.strip()))


def parse_detail(html: str) -> Detail:
    p = DetailParser()
    p.feed(html)
    lines = [_clean(line) for line in "".join(p.body_parts).splitlines()]
    # 작성자·등록일 칸은 '작성자 학생처', '등록일 2026.11.18'처럼 이름표가 앞에 붙는다
    writer = re.sub(r"^작성자\s*", "", _joined(p.writer))
    date = re.sub(r"^등록일\s*", "", _joined(p.date))
    return Detail(
        title=_joined(p.title_parts),
        department=writer or None,
        posted_date=_date(date),
        attachments=p.attachments,
        body_text="\n".join(line for line in lines if line),
        body_image_count=p.images,
    )
