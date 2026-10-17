"""본문 날짜의 결정적 파싱 (SPEC §6 수집·분석 4).

- 연도가 있는 날짜만 단독으로 인정한다. 연도 없는 날짜는 같은 줄의 범위 끝(A ~ B)일 때만 A의 연도를 따르고, A보다 앞서면 다음 해로 본다.
- 시각이 없으면 precision=date, time=null. 임의 마감시각(23:59)을 넣지 않는다.
- 시간대는 시각이 있고 출처 설정에 근거가 있을 때만 넣는다.
- evidence는 원문 줄 그대로다.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date

_SEP = r"\s*[.\-/년]\s*"
_FULL = re.compile(
    r"(?P<y>20\d{2})" + _SEP + r"(?P<m>\d{1,2})\s*[.\-/월]\s*(?P<d>\d{1,2})\s*[.일]?\s*"
    r"(?:\((?P<wd>[월화수목금토일])\))?\s*(?:(?P<h>\d{1,2})\s*:\s*(?P<mi>\d{2}))?"
)
_SHORT = re.compile(
    r"(?P<m>\d{1,2})\s*[.\-/월]\s*(?P<d>\d{1,2})\s*[.일]?\s*(?:\((?P<wd>[월화수목금토일])\))?\s*"
    r"(?:(?P<h>\d{1,2})\s*:\s*(?P<mi>\d{2}))?"
)
_TIME = re.compile(r"(?P<h>\d{1,2})\s*:\s*(?P<mi>\d{2})")
_RANGE_SEP = re.compile(r"\s*[~∼～\-–]\s*")


@dataclass(frozen=True)
class Point:
    day: date
    time: str | None


def _point(m: re.Match, year: int) -> Point | None:
    try:
        day = date(year, int(m["m"]), int(m["d"]))
    except ValueError:
        return None
    time = None
    if m["h"] is not None:
        h, mi = int(m["h"]), int(m["mi"])
        if h > 23 or mi > 59:
            return None
        time = f"{h:02d}:{mi:02d}"
    return Point(day, time)


def parse_line(line: str) -> tuple[Point | None, Point | None]:
    """한 줄에서 (첫 날짜, 범위 끝 날짜)를 찾는다. 범위가 아니면 끝은 None."""
    first = _FULL.search(line)
    if not first:
        return None, None
    start = _point(first, int(first["y"]))
    if start is None:
        return None, None
    rest = line[first.end():]
    sep = _RANGE_SEP.match(rest)
    if not sep:
        return start, None
    tail = rest[sep.end():]
    for pattern in (_FULL, _SHORT):
        m = pattern.match(tail)
        if m and (pattern is _FULL or m["wd"] or tail[m.end(): m.end() + 1] in ("", " ", ".", ",", ")", "까")):
            end = _point(m, int(m["y"]) if pattern is _FULL else start.day.year)
            if end and pattern is _SHORT and end.day < start.day:  # 12.30 ~ 01.05: 다음 해
                end = _point(m, start.day.year + 1)
            if end:
                return start, end
    m = _TIME.match(tail)
    if m and start.time:  # 같은 날 시각 범위: 15:00 ~ 17:00
        return start, _point_time(start.day, m)
    return start, None


def _point_time(day: date, m: re.Match) -> Point | None:
    h, mi = int(m["h"]), int(m["mi"])
    return Point(day, f"{h:02d}:{mi:02d}") if h <= 23 and mi <= 59 else None


def date_info(point: Point, evidence: str, timezone: str | None) -> dict:
    return {
        "date": point.day.isoformat(),
        "time": point.time,
        "timezone": timezone if point.time else None,
        "precision": "minute" if point.time else "date",
        "evidence": evidence,
    }
