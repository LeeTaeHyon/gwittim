"""알림톡 ↔ 게시판 공고 짝 찾기와 신청 사이트 주소 (D-025).

같은 행사를 학교가 게시판과 알림톡으로 함께 알리면 앱에 같은 공고가 두 번 보인다.
- 게시판 공고 제목의 핵심 낱말(프로그램 이름 등)이 알림톡 글에 거의 다 있으면 관련 공고로 본다.
- 알림톡 제목의 내용이 관련 게시판 공고들에 다 있으면 같은 공고로 보고 알림톡을 게시하지 않는다
  (게시판 공고에 원문 링크와 자세한 조건이 있다).
- 그 밖의 알림톡은 게시하고, 관련 게시판 공고를 '관련 학교 공지'로 붙인다.
- 알림톡 본문에 적힌 학교 사이트 주소(스마트케어 mpu 등)를 신청 사이트로 붙인다. 사이트는 수집하지 않는다.

낱말 기준이라 표현이 아주 다르면 놓친다. 놓치면 지금처럼 둘 다 보이고, 잘못 짝지으면 알림톡이 빠지므로
같은 공고는 양쪽 방향을 다 본다.
"""
from __future__ import annotations

import re
from datetime import date

# 바꾸면 올린다 (분석 버전에 붙어 알림톡 재분석을 일으킴)
MATCH_VERSION = "kmatch-0.1"

# 게시하는 알림톡 기준 게시판 공고 게시일 창: 게시판이 먼저 올라오는 경우가 많다
WINDOW_BEFORE_DAYS = 45  # 게시판 공고가 알림톡보다 이만큼 먼저
WINDOW_AFTER_DAYS = 7  # 게시판 공고가 알림톡보다 이만큼 늦게
MIN_COVER = 0.75  # 게시판 제목 핵심 낱말 중 알림톡에 있는 비율
MIN_HITS = 2  # 핵심 낱말이 하나만 겹치면('보건실' 등) 짝으로 보지 않는다
SAME_COVER = 0.7  # 알림톡 제목 핵심 낱말 중 관련 게시판 공고 제목들에 있는 비율. 실제 같은 공고 쌍은 0.75 이상 (D-025)
MAX_RELATED = 3

# 공고 제목에 흔해서 행사를 구별하지 못하는 말
_STOP = set(
    "안내 안내드립니다 안내사항 모집 참여 참가 신청 학생 학생들 여러분 프로그램 운영 실시 시행 공지 공지사항 관련 "
    "및 의 위한 대한 등 학기 학년도 혁신 명지전문대학 명지전문대 센터 바랍니다 많은 관심 진행 합니다 드립니다 "
    "있는 하는 대상 추가 개최 일정 결과 변경 연장".split()
)
_PREFIX = re.compile(r"^\s*(?:\[[^\]]*\]\s*)+")  # '[혁신]', '[취·창업팀]' 같은 머리말
_URL = re.compile(r"(?:https?://)?(?:[a-z0-9-]+\.)+mjc\.ac\.kr(?:/[^\s)\]>\"'<,]*)?", re.I)


def _key_words(title: str) -> set[str]:
    t = _PREFIX.sub("", title).lower().replace("c.r.e.w", "crew").replace("+", "plus")
    return {w for w in re.findall(r"[가-힣]+|[a-z]+", t) if len(w) >= 2 and w not in _STOP}


def _compact(text: str) -> str:
    return re.sub(r"[^가-힣a-z0-9]", "", text.lower().replace("c.r.e.w", "crew").replace("+", "plus"))


def _cover(words: set[str], text: str) -> tuple[float, int]:
    hits = sum(1 for w in words if w in text)
    return (hits / len(words) if words else 0.0), hits


def _in_window(kakao: dict, board: dict) -> bool:
    if not kakao.get("published") or not board.get("published"):
        return False
    gap = (date.fromisoformat(kakao["published"]["date"]) - date.fromisoformat(board["published"]["date"])).days
    return -WINDOW_AFTER_DAYS <= gap <= WINDOW_BEFORE_DAYS


def match_board(kakao: dict, body_text: str, notices: dict[str, dict]) -> tuple[list[dict], str | None]:
    """(관련 학교 공지 [{notice_id, title}], 같은 공고로 보는 게시판 notice_id 또는 None).

    관련: 게시판 공고 제목의 핵심 낱말이 알림톡 글(제목+본문)에 거의 다 있다.
    같은 공고: 거꾸로 알림톡 제목의 핵심 낱말도 관련 공고들 제목에 거의 다 있다. 1·2회차를 묶은 알림톡처럼
    게시판에 다 있는 내용이면 빼고, 'AI 카드뉴스'처럼 알림톡에만 있는 말이 제목에 남으면 둔다.
    """
    full_text = _compact(kakao["title"] + " " + body_text)
    related = []
    for n in notices.values():
        if not n["source_id"].startswith("mjc_www") or n["lifecycle_status"] == "removed" or not _in_window(kakao, n):
            continue
        cover, hits = _cover(_key_words(n["title"]), full_text)
        if cover >= MIN_COVER and hits >= MIN_HITS:
            related.append((cover, hits, n))
    related.sort(key=lambda r: (-r[0], -r[1], r[2]["notice_id"]))
    same = None
    words = _key_words(kakao["title"])
    if related:
        cover, hits = _cover(words, "".join(_compact(n["title"]) for _, _, n in related))
        if cover >= SAME_COVER and hits >= MIN_HITS:  # 짝은 알림톡 제목과 가장 잘 맞는 게시판 공고
            same = max(related, key=lambda r: (_cover(words, _compact(r[2]["title"])), r[0]))[2]["notice_id"]
    return [{"notice_id": n["notice_id"], "title": n["title"]} for _, _, n in related[:MAX_RELATED]], same


def apply_url(body_text: str) -> str | None:
    """알림톡 본문에 처음 나오는 학교 사이트 주소(*.mjc.ac.kr). 신청·안내 사이트로 보인다. 없으면 None."""
    m = _URL.search(body_text)
    if not m:
        return None
    url = m.group(0).rstrip(".")
    return url if url.lower().startswith("http") else "https://" + url
