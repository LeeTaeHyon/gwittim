"""유사 공고 점수 (docs/agent-privacy-spec.md §12). 임베딩 없는 순수 함수.

점수 = 분류 일치 + 관심사·직무 꼬리표 겹침 수 x 가중치 + 제목 키워드 겹침 수 x 가중치.

가중치 근거 (큰 순서):
- CATEGORY_WEIGHT(10): 같은 분류는 공고 종류가 같다는 가장 강한 신호다. 꼬리표·키워드 몇 개보다 위에 둔다.
- TAG_WEIGHT(3): 공통 사전 코드라 의미가 정확하지만 한 공고에 여러 개 붙을 수 있어 분류보다 약하다.
- KEYWORD_WEIGHT(1): 제목 문자열 겹침은 우연이 많아 가장 약하다. 키워드만으로 분류 일치를 넘지 않도록
  MAX_KEYWORD_HITS(3)개까지만 센다.
필드가 없거나 None이면 빈 것으로 본다(상태 칸은 예외: 없으면 제외). 마감 미상(None)은 지난 것으로 추정하지 않는다.
"""
from __future__ import annotations

import re
from datetime import date

from .config import EXCLUDED_CATEGORIES, EXCLUDED_LIFECYCLE, EXCLUDED_PUBLICATION
from .ranking import is_stale

CATEGORY_WEIGHT = 10
TAG_WEIGHT = 3
KEYWORD_WEIGHT = 1
MAX_KEYWORD_HITS = 3
DEFAULT_LIMIT = 3

# 흔한 말. 이것만 겹치면 유사하다고 보지 않는다.
STOPWORDS = frozenset(
    {
        "모집", "안내", "공고", "신청", "접수", "참여", "참가", "지원", "공지", "알림", "관련",
        "대상", "진행", "개최", "실시", "선발", "및", "위한", "대한", "학생", "학교", "대학",
        "기간", "연장", "변경", "마감", "추가", "재공고", "안내문", "사항", "서식", "제출",
    }
)

_TOKEN = re.compile(r"[0-9A-Za-z가-힣]+")


def title_keywords(title: str | None) -> set[str]:
    """공백·문장부호로 자른 2글자 이상 토큰에서 숫자만인 것과 불용어를 뺀 집합."""
    tokens = (t.lower() for t in _TOKEN.findall(title or ""))
    return {t for t in tokens if len(t) >= 2 and not t.isdigit() and t not in STOPWORDS}


def _tags(notice: dict) -> set[str]:
    return set(notice.get("interest_tags") or ()) | set(notice.get("related_roles") or ())


def similarity_score(target: dict, candidate: dict) -> int:
    score = 0
    if target.get("category") and target.get("category") == candidate.get("category"):
        score += CATEGORY_WEIGHT
    score += TAG_WEIGHT * len(_tags(target) & _tags(candidate))
    hits = len(title_keywords(target.get("title")) & title_keywords(candidate.get("title")))
    return score + KEYWORD_WEIGHT * min(hits, MAX_KEYWORD_HITS)


def _deadline(notice: dict) -> date | None:
    deadline = notice.get("application_deadline")
    return date.fromisoformat(deadline["date"]) if deadline else None


def is_excluded(notice: dict, today: date) -> bool:
    """기본 추천(ranking.recommend)이 빼는 공고는 유사 공고에서도 뺀다.

    끝났거나 내려간 공고(closed·removed), 게시 전(review_pending), 행정 공지(admin_notice),
    마감 미상인 채 오래된 공고(is_stale).
    상태 칸(lifecycle_status·publication_status)이 없으면 게시 여부를 알 수 없으므로 뺀다.
    """
    lifecycle = notice.get("lifecycle_status")
    publication = notice.get("publication_status")
    if lifecycle is None or publication is None:
        return True
    return (
        lifecycle in EXCLUDED_LIFECYCLE
        or publication in EXCLUDED_PUBLICATION
        or notice.get("category") in EXCLUDED_CATEGORIES
        or is_stale({"lifecycle_status": lifecycle, "published": notice.get("published")}, today)
    )


def similar_notices(target: dict, candidates: list[dict], today: date, limit: int = DEFAULT_LIMIT) -> list[dict]:
    """target과 비슷한 공고를 점수 내림차순으로 최대 limit개.

    제외: 같은 notice_id, is_excluded(기본 추천과 같은 제외 규칙), 마감 날짜가 today(Asia/Seoul 기준,
    호출자가 넘김)보다 앞선 공고, 점수 0.
    마감일이 today 당일이면 아직 지나지 않았으므로 포함한다. 마감 미상은 포함하되 동점에서 맨 뒤.
    동점: 마감 가까운 순, 그다음 notice_id.
    """
    ranked = []
    for cand in candidates:
        if cand.get("notice_id") == target.get("notice_id") or is_excluded(cand, today):
            continue
        deadline = _deadline(cand)
        if deadline is not None and deadline < today:
            continue
        points = similarity_score(target, cand)
        if points <= 0:
            continue
        ranked.append((-points, deadline is None, deadline or date.max, cand["notice_id"], cand))
    ranked.sort(key=lambda r: r[:4])
    return [r[4] for r in ranked[: max(limit, 0)]]
