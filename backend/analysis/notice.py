"""RawNotice 기록 → Notice 생성과 검증 (SPEC §6 수집·분석 4~7).

검증에 실패한 공고는 publication_status=review_pending으로 두고 기본 추천에서 빠진다.
"""
from __future__ import annotations

import hashlib
import re
from datetime import date

from backend.collectors.common import RawRecord
from backend.contracts import schema_errors
from backend.sources import source_config

from .rules import Analyzer, RuleBasedAnalyzer

CHANGE_TRACKED = (
    "title",
    "summary",
    "category",
    "interest_tags",
    "related_majors",
    "related_roles",
    "published",
    "application_start",
    "application_deadline",
    "deadline_note",
    "activity_period",
    "eligibility",
    "lifecycle_status",
    "source_url",
)


def notice_id_for(key: str) -> str:
    return "n_" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:20]


# 제목에 모집이 끝났다고 적힌 공고 (근로게시판의 '[모집완료]', '(마감)' 등). '마감 임박'·'마감 연장'은 아니다.
CLOSED_TITLE = re.compile(r"[\[(]\s*(?:모집\s*)?(?:마감|완료)\s*[\])]|모집\s*완료|모집\s*마감(?!\s*(?:일|임박|연장))")


# 알림톡은 신청 마감 없이 특강·검사 날짜만 알리는 안내가 많다. 마감일이 없으면 활동 기간(본문의 마지막 날짜)이
# 지났을 때 끝난 공고로 본다 (D-019). 게시판 공고에는 쓰지 않는다: 활동 기간이 길고 활동 중에도 안내가 유효한 경우가 많다.
ACTIVITY_CLOSES = {"mjc_kakao"}


def lifecycle(deadline: dict | None, today: date, title: str = "", activity: dict | None = None) -> str:
    if CLOSED_TITLE.search(title):
        return "closed"
    if deadline is None:
        last = activity and (activity["end"] or activity["start"])
        return "closed" if last and date.fromisoformat(last["date"]) < today else "unknown"
    return "closed" if date.fromisoformat(deadline["date"]) < today else "open"


def _lifecycle(notice: dict, today: date) -> str:
    activity = notice["activity_period"] if notice["source_id"] in ACTIVITY_CLOSES else None
    return lifecycle(notice["application_deadline"], today, notice["title"], activity)


def _without_evidence(value):
    """변경 비교용: 근거 문구만 바뀐 경우는 값 변경으로 보지 않는다."""
    if isinstance(value, dict):
        return {k: _without_evidence(v) for k, v in value.items() if k not in ("evidence", "unrestricted_evidence")}
    if isinstance(value, list):
        return [_without_evidence(v) for v in value]
    return value


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _evidences(notice: dict):
    for field in ("published", "application_start", "application_deadline"):
        if notice[field]:
            yield field, notice[field]["evidence"]
    if period := notice["activity_period"]:
        yield "activity_period", period["evidence"]
        for part in ("start", "end"):
            if period[part]:
                yield "activity_period", period[part]["evidence"]
    elig = notice["eligibility"]
    for c in elig["conditions"]:
        yield "eligibility", c["evidence"]
    for u in elig["unresolved_conditions"]:
        yield "eligibility", u["evidence"]
    if elig["unrestricted_evidence"]:
        yield "eligibility", elig["unrestricted_evidence"]


def validate(notice: dict, raw: dict) -> list[str]:
    """스키마 + 원문 근거 존재 + 날짜 순서. 근거가 있다는 것만으로 해석이 맞다고 보지는 않는다."""
    issues = schema_errors("notice", notice)
    if issues:
        return issues
    source_text = _normalize(raw["title"] + " " + raw["body_text"])
    for field, evidence in _evidences(notice):
        if field == "published":
            continue  # 게시일 근거는 목록 메타데이터에서 옴
        if _normalize(evidence) not in source_text:
            issues.append(f"{field}: 원문에 없는 근거 '{evidence[:40]}'")
    start, end = notice["application_start"], notice["application_deadline"]
    if start and end and start["date"] > end["date"]:
        issues.append("application_start가 마감보다 늦음")
    if (period := notice["activity_period"]) and period["start"] and period["end"] and period["start"]["date"] > period["end"]["date"]:
        issues.append("activity_period 시작이 끝보다 늦음")
    if raw["published"] and end:
        gap = date.fromisoformat(end["date"]).year - date.fromisoformat(raw["published"]["date"]).year
        if not 0 <= gap <= 1:
            issues.append("마감 연도가 게시 연도와 맞지 않음")
    return issues


def build_notice(
    record: RawRecord,
    *,
    today: date,
    previous: dict | None = None,
    analyzer: Analyzer | None = None,
) -> tuple[dict, list[str]]:
    """(Notice, 검증 문제 목록)을 돌려준다. 같은 원문 버전·분석기 버전이면 이전 분석을 재사용한다."""
    analyzer = analyzer or RuleBasedAnalyzer()
    raw = record.raw
    if previous and previous["notice_version"] == record.notice_version and previous["analysis_version"] == analyzer.version:
        reused = dict(previous, last_collected_at=record.last_collected_at, changed_fields=[])
        reused["lifecycle_status"] = "removed" if record.removed else _lifecycle(reused, today)
        if reused["lifecycle_status"] != previous["lifecycle_status"]:
            reused["changed_fields"] = ["lifecycle_status"]
        return reused, []

    fields = analyzer.analyze(raw, source_config(raw["source_id"]))
    # LLM 실패 시 분석기는 규칙 분석 결과와 그 버전을 돌려준다 (예전·다른 분석을 LLM 결과처럼 표시하지 않음)
    version = fields.pop("_analysis_version", analyzer.version)
    notice = {
        "schema_version": "1.0",
        "notice_id": notice_id_for(record.key),
        "source_id": raw["source_id"],
        "source_url": raw["source_url"],
        "title": raw["title"],
        "summary": fields["summary"],
        "category": fields["category"],
        "interest_tags": fields["interest_tags"],
        "related_majors": fields["related_majors"],
        "related_roles": fields["related_roles"],
        "published": raw["published"],
        "application_start": fields["application_start"],
        "application_deadline": fields["application_deadline"],
        "deadline_note": fields["deadline_note"],
        "activity_period": fields["activity_period"],
        "eligibility": fields["eligibility"],
        "lifecycle_status": None,
        "publication_status": "published",
        "notice_version": record.notice_version,
        "analysis_version": version,
        "last_collected_at": record.last_collected_at,
        "last_verified_at": raw["collected_at"],
        "changed_fields": [],
    }
    notice["lifecycle_status"] = "removed" if record.removed else _lifecycle(notice, today)
    if previous:
        notice["changed_fields"] = [
            f for f in CHANGE_TRACKED if _without_evidence(notice[f]) != _without_evidence(previous.get(f))
        ]
    issues = validate(notice, raw)
    if issues:
        notice["publication_status"] = "review_pending"
    return notice, issues
