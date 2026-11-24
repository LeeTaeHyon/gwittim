"""콘테스트코리아(contestkorea.com) 대회·공모전 목록·상세 HTML 파서. 표준 라이브러리 html.parser만 쓴다.

목록: div.list_style_2 > ul > li. 제목 div.title a(view.php?...&str_no=번호) 안의 span.category·span.txt,
      주최 ul.host li.icon_1, 대상 li.icon_2, 접수 span.step-1, 상태 div.d-day span.condition.
상세: div.view_top_area h1 제목, div.txt_area table(th 이름·td 값), div.view_detail_area div.txt 본문.
      본문 안의 사이트 자체 'AI 요약·분석'(tip_box2·3)과 복사 안내·해시태그(tip_box4)는 원문이 아니라 뺀다.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlsplit

from backend.collectors.common.external import clean_text, mask_contacts

_BLOCK = {"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "table", "ul", "ol"}
_OPEN_WORDS = re.compile(r"접수\s*중|접수\s*예정|마감\s*임박")
_ENDED_WORDS = re.compile(r"심사|발표|마감|종료|완료|결과|취소")
SNS_HEADING = "주최·주관사 SNS 채널"
_SKIP_BODY = {("h2", "tip2"), ("p", "tip_box2"), ("h2", "tip3"), ("p", "tip_box3"), ("p", "tip_box4"), ("div", "img_area"), ("h1", "line")}


def _flat(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


@dataclass
class ListRow:
    str_no: str
    bcode: str
    title: str
    category: str
    host: str
    audience: str  # 대상 칸 ('대학생, 대학원생')
    status: str  # 접수중 | 접수예정 | 심사대기 ...

    @property
    def ended(self) -> bool:
        """사이트가 접수 끝남으로 표시한 행. 접수중·접수예정·마감임박은 열려 있다. 상태 글이 없으면 거르지 않는다."""
        if _OPEN_WORDS.search(self.status):
            return False
        return bool(_ENDED_WORDS.search(self.status))


@dataclass
class Detail:
    title: str
    info: dict[str, str] = field(default_factory=dict)  # 상단 표: 이름 → 값
    links: dict[str, str] = field(default_factory=dict)  # 이름 → 주소 (홈페이지·접수하기)
    body_text: str = ""
    body_image_count: int = 0


class ListParser(HTMLParser):
    TARGETS = {("span", "category"): "category", ("span", "txt"): "title", ("li", "icon_1"): "host", ("li", "icon_2"): "audience",
               ("span", "step-1"): "period", ("span", "condition"): "status"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[ListRow] = []
        self._area = 0  # div.list_style_2 깊이
        self._row: dict | None = None
        self._li_depth = 0
        self._cur: str | None = None
        self._cur_tag = ""
        self._cur_depth = 0
        self._buf: list[str] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag == "div":
            if self._area:
                self._area += 1
            elif "list_style_2" in cls:
                self._area = 1
        if not self._area:
            return
        if tag == "li":
            if self._row is None:
                self._row, self._li_depth = {"str_no": None, "bcode": "", "title": "", "category": "", "host": "", "audience": "", "status": ""}, 1
            else:
                self._li_depth += 1
        if self._row is None:
            return
        if tag == "a" and self._row["str_no"] is None and "str_no=" in (a.get("href") or ""):
            q = parse_qs(urlsplit(a["href"]).query)
            if q.get("str_no"):
                self._row["str_no"], self._row["bcode"] = q["str_no"][0], (q.get("Txt_bcode") or [""])[0]
        if self._cur:
            if tag == self._cur_tag:
                self._cur_depth += 1
            return
        for (t, c), name in self.TARGETS.items():
            if tag == t and c in cls:
                self._cur, self._cur_tag, self._cur_depth, self._buf = name, tag, 1, []
                break

    def handle_endtag(self, tag):
        if not self._area:
            return
        if self._cur and tag == self._cur_tag:
            self._cur_depth -= 1
            if self._cur_depth == 0:
                self._row[self._cur] = _flat("".join(self._buf))
                self._cur = None
        if tag == "li" and self._row is not None:
            self._li_depth -= 1
            if self._li_depth == 0:
                row, self._row = self._row, None
                if row["str_no"]:
                    host = re.sub(r"^주최\s*\.?\s*", "", row["host"])
                    audience = re.sub(r"\s*,\s*", ", ", re.sub(r"^대상\s*\.?\s*", "", row["audience"]))
                    self.rows.append(
                        ListRow(row["str_no"], row["bcode"], row["title"], row["category"], host, audience, row["status"])
                    )
        if tag == "div":
            self._area -= 1

    def handle_data(self, data):
        if self._cur:
            self._buf.append(data)


class DetailParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.info: dict[str, str] = {}
        self.links: dict[str, str] = {}
        self.body_parts: list[str] = []
        self.images = 0
        self._in_top = False
        self._top_depth = 0
        self._in_h1 = False
        self._title_done = False
        self._in_table = False
        self._th: list[str] | None = None
        self._td: list[str] | None = None
        self._label = ""
        self._link: str | None = None
        self._area_depth = 0  # div.view_detail_area
        self._txt_depth = 0  # 그 안의 첫 div.txt
        self._txt_done = False
        self._skip_tag: str | None = None
        self._skip_depth = 0
        self._stopped = False  # '주최·주관사 SNS 채널' 머리글부터는 본문이 아니라 SNS 링크 모음
        self._skip = 0  # script/style

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag in ("script", "style"):
            self._skip += 1
            return
        if self._txt_depth:
            if self._skip_tag:
                if tag == self._skip_tag:
                    self._skip_depth += 1
                elif tag == "img" and self._skip_tag == "div" and not self._stopped:
                    self.images += 1  # 대회 포스터 이미지: 글로 읽지 못한 내용이 있을 수 있어 센다
                return
            if any((tag, c) in _SKIP_BODY for c in cls):
                self._skip_tag, self._skip_depth = tag, 1  # 건너뛰는 덩어리 안의 같은 태그는 skip_depth로만 센다
                return
            if tag == "div":
                self._txt_depth += 1
            if tag in _BLOCK:
                self.body_parts.append("\n")
            elif tag == "img" and not self._stopped:
                self.images += 1
            return
        if self._area_depth:
            if tag == "div":
                self._area_depth += 1
                if "txt" in cls and not self._txt_done:
                    self._txt_depth = 1
            return
        if tag == "div" and "view_detail_area" in cls:
            self._area_depth = 1
        elif tag == "div" and "view_top_area" in cls:
            self._in_top, self._top_depth = True, 1
        elif self._in_top:
            if tag == "div":
                self._top_depth += 1
            elif tag == "h1" and not self._title_done:
                self._in_h1 = True
            elif tag == "table":
                self._in_table = True
            elif self._in_table:
                if tag == "th":
                    self._th = []
                elif tag == "td":
                    self._td, self._link = [], None
                elif tag == "a" and self._td is not None:
                    href = a.get("href") or ""
                    url = href if href.startswith("http") else (a.get("val2") or "")
                    if url.startswith("http") and self._link is None:
                        self._link = url

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = max(0, self._skip - 1)
            return
        if self._txt_depth:
            if self._skip_tag:
                if tag == self._skip_tag:
                    self._skip_depth -= 1
                    if self._skip_depth == 0:
                        self._skip_tag = None
                        self.body_parts.append("\n")
                return
            if tag == "div":
                self._txt_depth -= 1
                if self._txt_depth == 0:
                    self._txt_done = True
            elif tag in _BLOCK:
                self.body_parts.append("\n")
            return
        if self._area_depth:
            if tag == "div":
                self._area_depth -= 1
            return
        if self._in_top:
            if tag == "div":
                self._top_depth -= 1
                if self._top_depth == 0:
                    self._in_top = False
            elif tag == "h1" and self._in_h1:
                self._in_h1, self._title_done = False, True
            elif tag == "table":
                self._in_table = False
            elif tag == "th" and self._th is not None:
                self._label, self._th = _flat("".join(self._th)), None
            elif tag == "td" and self._td is not None:
                value = _flat("".join(self._td))
                if self._label:
                    self.info.setdefault(self._label, value)
                    if self._link:
                        self.links.setdefault(self._label, self._link)
                self._td, self._label = None, ""

    def handle_data(self, data):
        if self._skip:
            return
        if self._txt_depth:
            if data.strip() == SNS_HEADING:
                self._stopped = True
            if not self._skip_tag and not self._stopped:
                self.body_parts.append(data)
        elif self._in_h1:
            self.title_parts.append(data)
        elif self._th is not None:
            self._th.append(data)
        elif self._td is not None:
            self._td.append(data)


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
        title=_flat("".join(p.title_parts)),
        info=p.info,
        links=p.links,
        body_text=body,
        body_image_count=p.images,
    )
