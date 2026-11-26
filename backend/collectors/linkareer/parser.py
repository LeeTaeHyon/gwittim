"""링커리어 목록·상세 파서. 표준 라이브러리만 쓴다.

링커리어는 Next.js 사이트라 목록·상세 HTML 안의 `<script id="__NEXT_DATA__">` JSON(서버 렌더 결과)에 내용이 들어 있다.
내부 API(GraphQL)는 부르지 않는다.

목록: props.pageProps.activityItems가 본문 목록의 순서(주소 /activity/번호)이고, 같은 순서의 항목이 __APOLLO_STATE__의
      Activity:번호에 있다(제목·주최·마감 시각 recruitCloseAt). Apollo에는 사이드 추천 공고도 섞여 있어 activityItems에 있는 것만 쓴다.
상세: __APOLLO_STATE__의 Activity:번호와 참조(__ref)로 연결된 항목(대상·분야·혜택·본문 HTML detailText).
시각: recruitCloseAt 등은 epoch 밀리초다. 사이트가 한국 서비스라 한국 날짜로 바꾸되 시각은 쓰지 않고 날짜만 쓴다(시간대 미확정, D-038).
"""
from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from backend.collectors.common.external import clean_text, html_to_text

KST = timezone(timedelta(hours=9), "Asia/Seoul")
_NEXT = re.compile(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', re.S)
TYPE_ACTIVITY, TYPE_EDUCATION, TYPE_CONTEST = 1, 6, 3  # activityTypeID (2026-11-26 관찰: 대외활동 1, 공모전 3, 교육 6)


def _apollo(html: str) -> tuple[dict, dict]:
    m = _NEXT.search(html)
    if not m:
        return {}, {}
    page = json.loads(m[1]).get("props", {}).get("pageProps", {})
    return page, page.get("__APOLLO_STATE__") or {}


def ms_to_date(ms: int | None) -> str | None:
    """epoch 밀리초 → 한국 날짜(YYYY-MM-DD). 시각은 버린다."""
    if not ms:
        return None
    return datetime.fromtimestamp(ms / 1000, KST).strftime("%Y-%m-%d")


@dataclass
class ListRow:
    id: str
    title: str
    organizer: str
    close_ms: int | None
    recruit_type: str  # NORMAL | ASAP(충원 시 마감)
    type_id: int | None
    now_ms: int = 0  # 목록을 읽은 시각. 마감 비교용

    @property
    def ended(self) -> bool:
        """마감일이 이미 지난 행. 충원 시 마감(ASAP)은 표시된 날짜로 거르지 않는다."""
        return self.recruit_type != "ASAP" and bool(self.close_ms) and self.close_ms < self.now_ms


@dataclass
class Detail:
    id: str
    title: str
    organizer: str = ""
    organization_type: str = ""
    categories: list[str] = field(default_factory=list)
    targets: list[str] = field(default_factory=list)
    benefits: list[str] = field(default_factory=list)
    apply_types: list[str] = field(default_factory=list)
    apply_url: str | None = None
    homepage: str | None = None
    recruit_type: str = "NORMAL"
    recruit_start: str | None = None
    recruit_close: str | None = None
    activity_start: str | None = None
    activity_end: str | None = None
    reward_man: int | None = None  # 상금 만원
    scale: str | None = None
    status: str | None = None
    body_text: str = ""
    body_image_count: int = 0


def parse_list(html: str, now_ms: int | None = None, type_id: int | None = None) -> list[ListRow]:
    """본문 목록 행. type_id를 주면 그 종류(공모전 3·대외활동 1)만 남긴다(/list/activity에는 교육(6)도 섞인다)."""
    page, ap = _apollo(html)
    now = int(time.time() * 1000) if now_ms is None else now_ms
    rows: list[ListRow] = []
    for item in page.get("activityItems") or []:
        m = re.search(r"/activity/(\d+)", item.get("url") or "")
        a = ap.get(f"Activity:{m[1]}") if m else None
        if not a:
            continue
        if type_id is not None and a.get("activityTypeID") != type_id:
            continue
        rows.append(ListRow(m[1], clean_text(a.get("title") or item.get("name") or ""), clean_text(a.get("organizationName") or ""),
                            a.get("recruitCloseAt"), a.get("recruitType") or "NORMAL", a.get("activityTypeID"), now))
    return rows


def parse_detail(html: str, activity_id: str) -> Detail | None:
    """상세 Activity를 읽는다. 담당자 이름·연락처는 읽지 않는다(managerName·managerPhoneNumber·managerEmail 미사용)."""
    _, ap = _apollo(html)
    a = ap.get(f"Activity:{activity_id}")
    if not a:
        return None

    def ref(x):
        return ap.get(x["__ref"]) if isinstance(x, dict) and "__ref" in x else None

    def names(key: str) -> list[str]:
        return [n["name"] for n in (ref(i) for i in a.get(key) or []) if n and n.get("name")]

    text = (ref(a.get("detailText")) or {}).get("text") or ""
    body, images = html_to_text(text)
    reward = None
    for i in a.get("integers") or []:
        node = ref(i) or {}
        if (ref(node.get("type")) or {}).get("id") == "1" and str(node.get("integer") or "").isdigit():
            reward = int(node["integer"])  # 2026-11-26 관찰: 상금 유형(만원) id 1
    reward = reward or a.get("tenThousandUnitOfReward") or None
    apply_detail = (a.get("applyDetail") or "").strip()
    return Detail(
        id=activity_id,
        title=clean_text(a.get("title") or ""),
        organizer=clean_text(a.get("organizationName") or ""),
        organization_type=clean_text(a.get("organizationType") or ""),
        categories=names("rootCategories") or names("categories"),
        targets=names("targets"),
        benefits=names("benefits"),
        apply_types=names("applyTypes"),
        apply_url=apply_detail if apply_detail.startswith("http") else None,
        homepage=a.get("homepageURL") or None,
        recruit_type=a.get("recruitType") or "NORMAL",
        recruit_start=ms_to_date(a.get("recruitStartAt")),
        recruit_close=ms_to_date(a.get("recruitCloseAt")),
        activity_start=ms_to_date(a.get("activityStartAt")),
        activity_end=ms_to_date(a.get("activityEndAt")),
        reward_man=reward,
        scale=a.get("recruitScale") or None,
        status=a.get("status"),
        body_text=body,
        body_image_count=images,
    )
