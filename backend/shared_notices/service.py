"""카카오톡 공고 수동 전달: 가린 글을 받아 분석·저장하고 본인 목록을 돌려준다 (docs/kakao-manual-share-spec.md).

- 앱이 기기에서 먼저 가린 글을 보낸다. 서버도 같은 파이썬 파서로 한 번 더 확인하고 가린 뒤 저장한다 (D-036과 같은 원칙).
- 개인 알림·잡음이면 분석·저장하지 않는다. LLM 호출·크레딧 차감 없음.
- 분석은 알림톡 분석기(Gemma 없음)를 쓴다. 연도 없는 날짜는 넘긴 날(KST) 기준 가까운 해로 읽는다 (D-019).
- 원문 이미지는 받지 않는다. 글·uid·분석 결과는 로그에 남기지 않는다.
"""
from __future__ import annotations

import hashlib
import logging
import secrets
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING

from backend.analysis.kakao import KakaoAnalyzer
from backend.analysis.notice import build_notice
from backend.classifier.cascade import MODEL_VERSION
from backend.collectors.common import RawRecord, content_hash
from backend.collectors.mjc_kakao.parser import classify as kakao_kind
from backend.collectors.mjc_kakao.parser import clean_body, mask, title_of
from backend.contracts import schema_errors
from backend.recommendation import evaluate

if TYPE_CHECKING:
    from backend.api.deps import Deps

log = logging.getLogger("gwittim.shared_notices")

SOURCE_ID = "user_share"
SHARE_CONSENT_VERSION = "2026-11-26"  # 동의 문구가 바뀌면 올린다. 앱 shareConsentVersion과 같아야 한다
DAILY_LIMIT = 30
LIST_LIMIT = 50
DEFAULT_TITLE = "카카오톡에서 넘긴 공고"
# 분석·저장하지 않는 종류 (개인 알림·잡음). participant(참여 학생 대상 안내)는 본인이 받은 글이라 분석한다
NOT_ANALYZED = {"personal_course", "personal_account", "noise"}

_KST = timezone(timedelta(hours=9), "Asia/Seoul")
_EMPTY_PROFILE = {
    "university_id": None,
    "major_id": None,
    "grade": None,
    "enrollment_status": None,
    "interest_ids": [],
    "target_role_ids": [],
}
_analyzer: KakaoAnalyzer | None = None


class ShareError(Exception):
    """code는 api_error 계약의 오류 코드."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _get_analyzer() -> KakaoAnalyzer:
    global _analyzer
    if _analyzer is None:
        _analyzer = KakaoAnalyzer(gemma=None)  # 서버에 Gemma 없음: 애매해도 모델 답 그대로
    return _analyzer


def _day_start_iso(now: datetime) -> str:
    start = now.astimezone(_KST).replace(hour=0, minute=0, second=0, microsecond=0)
    return start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _text_hash(masked: str) -> str:
    """공백을 정리한 가린 본문의 해시. 같은 글을 다시 붙여넣었는지 가리는 기준."""
    return hashlib.sha256(" ".join(masked.split()).encode("utf-8")).hexdigest()


def _item(doc: dict, profile: dict | None) -> dict:
    status, results = evaluate(doc["notice"]["eligibility"], profile or _EMPTY_PROFILE)
    return {
        "id": doc["id"],
        "created_at": doc["created_at"],
        "input": doc["input"],
        "notice": doc["notice"],
        "eligibility": {"eligibility_status": status, "condition_results": results},
    }


def submit(uid: str, body: dict, deps: Deps) -> dict:
    """가린 글 → 분석·저장 → 응답 항목. 개인 알림이면 {'stored': False, 'reason': 'personal_notice'}."""
    if not isinstance(body, dict) or schema_errors("shared_notice_request", body):
        raise ShareError("invalid_argument")
    if body["consent_version"] != SHARE_CONSENT_VERSION:
        raise ShareError("consent_required")

    cleaned = clean_body({"lines": body["text"].splitlines()})
    # 서버에는 받는 사람 이름 목록이 없다. 기기가 이름까지 가렸고, 학번·수강 과목 같은 규칙은 이름 없이도 걸린다
    if kakao_kind(cleaned, ()) in NOT_ANALYZED:
        return {"stored": False, "reason": "personal_notice"}

    masked = mask(cleaned, ())
    # 같은 사용자가 같은 글을 다시 넘기면 새로 저장하지 않고 기존 항목을 돌려준다(하루 상한에도 세지 않는다)
    digest = _text_hash(masked)
    for old in deps.shared.list(uid):
        if _text_hash(old.get("text", "")) == digest:
            return _item(old, deps.profiles.get(uid))

    now = deps.clock.now()
    if deps.shared.count_since(uid, _day_start_iso(now)) >= DAILY_LIMIT:
        raise ShareError("rate_limited")

    today = deps.today_kst()
    now_iso = deps.now_iso()
    share_id = secrets.token_urlsafe(16)  # 서버 생성, 추측 불가
    raw = {
        "schema_version": "1.0",
        "source_id": SOURCE_ID,
        "source_notice_id": share_id,
        "source_url": None,
        "title": title_of(masked, "") or DEFAULT_TITLE,
        "body_text": masked,
        # 카톡 공유 글에는 발송일이 없다. 넘긴 날을 기준일로 쓴다(알려진 한계). 시각·시간대는 모름
        "published": {
            "date": today.isoformat(),
            "time": None,
            "timezone": None,
            "precision": "date",
            "evidence": f"카카오톡에서 넘긴 날 {today.isoformat()}",
        },
        "collected_at": now_iso,
        "content_hash": "",
        "source_fields": {"input": body["input"]},
        "attachments": [],
    }
    raw["content_hash"] = content_hash(raw)
    if schema_errors("raw_notice", raw):
        log.warning("shared raw invalid")
        raise ShareError("unavailable")

    record = RawRecord(f"{SOURCE_ID}|{share_id}", raw, raw["content_hash"], 1, now_iso, now_iso)
    try:
        notice, issues = build_notice(record, today=today, analyzer=_get_analyzer())
    except Exception as exc:  # 분석 실패는 저장하지 않는다. 글은 로그에 남기지 않는다
        log.warning("shared analysis failed error=%s", type(exc).__name__)
        raise ShareError("unavailable") from None
    if issues:
        # 검증 문제가 있어도 본인에게는 보여 준다. build_notice가 review_pending으로 두었다(게시 상태 아님)
        log.info("shared notice issues=%d", len(issues))

    doc = {
        "id": share_id,
        "created_at": now_iso,
        "input": body["input"],
        "text": masked,  # 가린 본문. 학습용으로 저장
        "notice": notice,
        "analysis_version": notice["analysis_version"],
        "model_version": MODEL_VERSION,
        "consent_version": body["consent_version"],
    }
    if body["input"] == "share_image_ocr":
        doc["ocr_edited"] = body["ocr_edited"]
    try:
        deps.shared.put(uid, doc)
    except Exception as exc:
        log.warning("shared store failed error=%s", type(exc).__name__)
        raise ShareError("unavailable") from None
    return _item(doc, deps.profiles.get(uid))


def list_items(uid: str, deps: Deps) -> dict:
    profile = deps.profiles.get(uid)
    return {
        "items": [_item(d, profile) for d in deps.shared.list(uid)[:LIST_LIMIT]],
        "next_cursor": None,
        "generated_at": deps.now_iso(),
    }


def delete_item(uid: str, share_id: str, deps: Deps) -> None:
    """본인 경로에서만 지운다. 없거나 남의 것이면 아무 일도 하지 않는다(반복 요청 안전)."""
    deps.shared.delete(uid, share_id)
