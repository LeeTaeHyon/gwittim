"""교외 출처끼리 같은 공고 찾기 (D-048).

위비티와 콘테스트코리아에 같은 공모전이 함께 올라와 앱에 두 번 보였다(2026-11-23 첫 교외 배치: 50건 중 2쌍).
두 사이트 모두 주최 측 공고를 옮겨 싣는 곳이라 제목과 접수 마감이 같다.

- 같은 공고: 접수 마감 날짜가 같고 제목이 거의 같다(머리말 괄호·기호를 뺀 글자 2-gram 겹침 0.85 이상, 또는 한쪽 제목이 다른 쪽에 통째로 들어감).
  마감을 한쪽이라도 모르면 더 엄격하게 0.9 이상
- 남길 쪽은 출처 순서로 정한다(EXTERNAL_PRIORITY 앞쪽). 배치 순서에 따라 남는 쪽이 바뀌지 않게 하기 위함
- 끝난 공고(closed·removed)와는 짝을 짓지 않는다. 앞 출처 공고가 끝나면 뒤 출처 공고가 다시 보일 수 있다
- 학교 공지·알림톡과의 짝은 보지 않는다(학교 공지는 알림톡 짝 D-025가 따로 있음)
"""
from __future__ import annotations

import re

# 앞쪽이 남는다. 위비티를 1차 출처로 정했다(D-038)
EXTERNAL_PRIORITY = ("wevity_contest", "contestkorea_contest")
SAME_TITLE = 0.85  # 0.7은 한 낱말만 다른 다른 공모전(광고·영상)을 같은 공고로 봄
SAME_TITLE_NO_DEADLINE = 0.9
_BRACKETS = re.compile(r"\[[^\]]*\]|\([^)]*\)|【[^】]*】|<[^>]*>")
_NOT_TEXT = re.compile(r"[^0-9a-z가-힣]")
_MIN_CONTAINED = 8  # 통째로 들어감을 볼 때 짧은 제목의 최소 글자 수


def _norm(title: str) -> str:
    return _NOT_TEXT.sub("", _BRACKETS.sub(" ", title or "").lower())


def _dice(a: str, b: str) -> float:
    ga = {a[i:i + 2] for i in range(len(a) - 1)}
    gb = {b[i:i + 2] for i in range(len(b) - 1)}
    return 2 * len(ga & gb) / (len(ga) + len(gb)) if ga and gb else 0.0


def _deadline(notice: dict) -> str | None:
    return (notice.get("application_deadline") or {}).get("date")


def same_notice(a: dict, b: dict) -> bool:
    """두 교외 공고가 같은 공고인지."""
    ta, tb = _norm(a.get("title", "")), _norm(b.get("title", ""))
    if not ta or not tb:
        return False
    da, db = _deadline(a), _deadline(b)
    if da and db:
        if da != db:
            return False
        short, long_ = sorted((ta, tb), key=len)
        return _dice(ta, tb) >= SAME_TITLE or (len(short) >= _MIN_CONTAINED and short in long_)
    return _dice(ta, tb) >= SAME_TITLE_NO_DEADLINE


def find_preferred_same(notice: dict, notices: dict[str, dict]) -> str | None:
    """notice보다 앞 출처에 같은 공고가 있으면 그 키. 없으면 None. notice가 교외 출처가 아니면 None."""
    source = notice.get("source_id")
    if source not in EXTERNAL_PRIORITY:
        return None
    ahead = EXTERNAL_PRIORITY[: EXTERNAL_PRIORITY.index(source)]
    for key, other in notices.items():
        if other.get("source_id") in ahead and other.get("lifecycle_status") not in ("closed", "removed") \
                and same_notice(notice, other):
            return key
    return None
