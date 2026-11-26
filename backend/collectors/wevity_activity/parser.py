"""위비티 대외활동 메뉴(?c=active) 목록 파서. 상세는 공모전 메뉴와 같은 구조라 wevity 파서를 그대로 쓴다.

목록: ul.ext-list > li (카드). 상세 링크 a(...&ix=번호), 남은 날 div.hide-dday('D-40'), 제목 div.hide-tit a, 분야 div.hide-cat.
공모전 목록(ul.list)과 달리 주최·접수 상태 칸이 없다. 마감 표시는 D-day 칸의 글('마감'·'D+')로 본다.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from html.parser import HTMLParser

from backend.collectors.common.external import clean_text

_IX = re.compile(r"[?&]ix=(\d+)")
_ENDED = re.compile(r"마감|종료|D\+\d")


@dataclass
class ListRow:
    ix: str
    title: str
    fields: str
    dday: str

    @property
    def ended(self) -> bool:
        """D-day 칸이 마감·종료로 표시된 행. 칸이 없으면 거르지 않는다."""
        return bool(_ENDED.search(self.dday))


class ListParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[ListRow] = []
        self._ul = 0
        self._row: dict | None = None
        self._cell: str | None = None
        self._depth = 0
        self._buf: list[str] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag == "ul":
            if self._ul:
                self._ul += 1
            elif "ext-list" in cls:
                self._ul = 1
            return
        if not self._ul:
            return
        if tag == "li" and self._row is None:
            self._row = {"ix": None, "tit": "", "cat": "", "dday": ""}
        elif self._row is None:
            return
        elif tag == "a" and self._row["ix"] is None and (m := _IX.search(a.get("href") or "")):
            self._row["ix"] = m[1]
        elif tag == "div":
            if self._cell:
                self._depth += 1
            else:
                for css, name in (("hide-dday", "dday"), ("hide-tit", "tit"), ("hide-cat", "cat")):
                    if css in cls:
                        self._cell, self._depth, self._buf = name, 1, []

    def handle_endtag(self, tag):
        if tag == "ul" and self._ul:
            self._ul -= 1
            return
        if self._row is None:
            return
        if tag == "div" and self._cell:
            self._depth -= 1
            if self._depth == 0:
                self._row[self._cell] = clean_text("".join(self._buf))
                self._cell = None
        elif tag == "li" and self._cell is None:
            row, self._row = self._row, None
            if row["ix"]:
                self.rows.append(ListRow(row["ix"], row["tit"], row["cat"], row["dday"]))

    def handle_data(self, data):
        if self._cell:
            self._buf.append(data)


def parse_list(html: str) -> list[ListRow]:
    p = ListParser()
    p.feed(html)
    return p.rows
