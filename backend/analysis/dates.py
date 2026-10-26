"""본문 날짜의 결정적 파싱 (SPEC §6 수집·분석 4).

- 연도가 있는 날짜만 단독으로 인정한다. 두 자리 연도(26.12.30(수))는 요일이 달력과 맞을 때만 인정한다. 연도 없는 날짜는 같은 줄의 범위 끝(A ~ B)일 때만 A의 연도를 따르고, A보다 앞서면 다음 해로 본다.
- 시각이 없으면 precision=date, time=null. 임의 마감시각(23:59)을 넣지 않는다.
- 시간대는 시각이 있고 출처 설정에 근거가 있을 때만 넣는다.
- evidence는 원문 줄 그대로다.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date

_SEP = r"\s*[.\-/년]\s*"
_CLOCK = r"(?:(?P<h>\d{1,2})\s*:\s*(?P<mi>\d{2})|(?P<kh>\d{1,2})\s*시(?:\s*(?P<kmi>\d{1,2})\s*분)?)"
_FULL = re.compile(
    r"(?P<y>20\d{2})" + _SEP + r"(?P<m>\d{1,2})\s*[.\-/월]\s*(?P<d>\d{1,2})\s*[.일]?\s*"
    r"(?:\((?P<wd>[월화수목금토일])\))?\s*(?:" + _CLOCK + r")?"
)
_SHORT = re.compile(
    r"(?P<m>\d{1,2})\s*[.\-/월]\s*(?P<d>\d{1,2})\s*[.일]?\s*(?:\((?P<wd>[월화수목금토일])\))?\s*"
    r"(?:" + _CLOCK + r")?"
)
# 두 자리 연도 '26.12.30(수)' (채용 포스터 대체텍스트에 흔함, D-014). 오인을 막으려고 요일이 붙고 달력과 맞을 때만 인정한다.
_YY = re.compile(
    r"(?<![\d.])(?P<y>2\d)\.\s*(?P<m>\d{1,2})\.\s*(?P<d>\d{1,2})\s*\.?\s*\((?P<wd>[월화수목금토일])\)\s*"
    r"(?:" + _CLOCK + r")?"
)
_WEEKDAYS = "월화수목금토일"
_TIME = re.compile(_CLOCK)
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
    clock = _clock(m)
    if clock is False:
        return None
    return Point(day, clock)


def _clock(m: re.Match) -> str | None | bool:
    """HH:MM 또는 HH시 [MM분]. 없으면 None, 범위 밖이면 False."""
    if m["h"] is not None:
        h, mi = int(m["h"]), int(m["mi"])
    elif m["kh"] is not None:
        h, mi = int(m["kh"]), int(m["kmi"] or 0)
    else:
        return None
    return f"{h:02d}:{mi:02d}" if h <= 23 and mi <= 59 else False


def _dated_point(m: re.Match) -> Point | None:
    """연도가 있는 날짜(_FULL 또는 _YY). 두 자리 연도는 요일이 실제 달력과 다르면 버린다."""
    if len(m["y"]) == 4:
        return _point(m, int(m["y"]))
    point = _point(m, 2000 + int(m["y"]))
    return point if point and _WEEKDAYS[point.day.weekday()] == m["wd"] else None


def parse_line(line: str) -> tuple[Point | None, Point | None]:
    """한 줄에서 (첫 날짜, 범위 끝 날짜)를 찾는다. 범위가 아니면 끝은 None."""
    first = _FULL.search(line) or _YY.search(line)
    if not first:
        return None, None
    start = _dated_point(first)
    if start is None:
        return None, None
    rest = line[first.end():]
    sep = _RANGE_SEP.match(rest)
    if not sep:
        return start, None
    tail = rest[sep.end():]
    for pattern in (_FULL, _YY, _SHORT):
        m = pattern.match(tail)
        if m and (pattern is not _SHORT or m["wd"] or tail[m.end(): m.end() + 1] in ("", " ", ".", ",", ")", "까")):
            end = _dated_point(m) if pattern is not _SHORT else _point(m, start.day.year)
            if end and pattern is _SHORT and end.day < start.day:  # 12.30 ~ 01.05: 다음 해
                end = _point(m, start.day.year + 1)
            if end:
                return start, end
    m = _TIME.match(tail)
    if m and start.time:  # 같은 날 시각 범위: 15:00 ~ 17:00
        return start, _point_time(start.day, m)
    return start, None


def _point_time(day: date, m: re.Match) -> Point | None:
    clock = _clock(m)
    return Point(day, clock) if clock else None


def date_info(point: Point, evidence: str, timezone: str | None) -> dict:
    return {
        "date": point.day.isoformat(),
        "time": point.time,
        "timezone": timezone if point.time else None,
        "precision": "minute" if point.time else "date",
        "evidence": evidence,
    }
