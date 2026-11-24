"""분석된 Notice를 게시 저장소에 반영한다 (W4, SPEC §6·§10).

컬렉션 구성 (firestore.rules와 같은 이름):
- notices/{notice_id}: 공개 공고. 앱은 로그인 사용자만 읽고, 쓰기는 서버만
- review_queue/{notice_id}: 검증 실패·검토 대기 (비공개)
- users/{uid}, users/{uid}/saved/{notice_id}: 본인만 읽기, 쓰기는 서버 API(W13)
- raw_notices, pipeline_failures: 원문 수집 자료·실패 기록 (비공개, 파이프라인 저장소)
- notice_bodies/{notice_id}: 게시한 공고의 본문(서버 전용, 앱 접근 금지). AI 상세 분석 입력용 (docs/agent-detail-body-spec.md)

Firestore 구현은 Firebase 프로젝트 생성 후 같은 인터페이스로 추가한다.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Protocol

from backend.contracts import schema_errors

NOTICES = "notices"
REVIEW_QUEUE = "review_queue"
USERS = "users"
SAVED = "saved"
RAW_NOTICES = "raw_notices"
PIPELINE_FAILURES = "pipeline_failures"
NOTICE_BODIES = "notice_bodies"

# 명단형 공지(합격자·선발 결과·수상자). 사람 이름이 줄지어 나올 수 있어 본문을 올리지 않는다
ROSTER = re.compile(r"합격자|선발\s*결과|선정\s*결과|수상자|최종\s*명단|명단\s*발표|결과\s*발표|당선작\s*발표")
MIN_BODY_CHARS = 20  # 이보다 짧으면(이미지·첨부만 있는 공고) 본문으로 쓸 내용이 없다


def body_for_storage(title: str, body: str | None) -> str | None:
    """저장할 본문. 명단형 제목, 비었거나 20자 미만이면 None(저장하지 않음). 앞뒤 공백만 뗀다."""
    text = body.strip() if isinstance(body, str) else ""
    if len(text) < MIN_BODY_CHARS or ROSTER.search(title or ""):
        return None
    return text


class PublishOutcome(str, Enum):
    PUBLISHED = "published"  # 공개 컬렉션에 쓰기
    QUEUED = "queued"  # 검토 대기로 보내고 공개본은 내림
    SKIPPED = "skipped"  # 공개본과 같은 버전·분석이면 다시 쓰지 않음


class NoticeSink(Protocol):
    def get_public(self, notice_id: str) -> dict | None: ...
    def put_public(self, notice: dict) -> None: ...
    def delete_public(self, notice_id: str) -> None: ...
    def touch_public(self, notice_id: str, fields: dict) -> None: ...
    def put_review(self, notice: dict, issues: list[str]) -> None: ...
    def delete_review(self, notice_id: str) -> None: ...
    # 서버 전용 본문. delete_public은 본문도 함께 지운다
    def get_body(self, notice_id: str) -> dict | None: ...
    def put_body(self, doc: dict) -> None: ...
    def delete_body(self, notice_id: str) -> None: ...


@dataclass
class InMemorySink:
    public: dict[str, dict] = field(default_factory=dict)
    review: dict[str, dict] = field(default_factory=dict)
    bodies: dict[str, dict] = field(default_factory=dict)

    def get_public(self, notice_id):
        return self.public.get(notice_id)

    def put_public(self, notice):
        self.public[notice["notice_id"]] = notice

    def delete_public(self, notice_id):
        self.public.pop(notice_id, None)
        self.bodies.pop(notice_id, None)

    def touch_public(self, notice_id, fields):
        self.public[notice_id] = {**self.public[notice_id], **fields}

    def put_review(self, notice, issues):
        self.review[notice["notice_id"]] = {"notice": notice, "issues": issues}

    def delete_review(self, notice_id):
        self.review.pop(notice_id, None)

    def get_body(self, notice_id):
        return self.bodies.get(notice_id)

    def put_body(self, doc):
        self.bodies[doc["notice_id"]] = doc

    def delete_body(self, notice_id):
        self.bodies.pop(notice_id, None)


def sync_body(notice: dict, body: str | None, sink: NoticeSink) -> None:
    """게시한 공고의 본문을 서버 전용 저장소에 맞춘다. 이미 같은 내용이면 쓰지 않는다(쓰기 횟수 절약).

    저장할 본문이 없으면(명단형·20자 미만·본문 없음) 예전에 올린 본문이 있을 때만 지운다.
    """
    notice_id = notice["notice_id"]
    text = body_for_storage(notice.get("title", ""), body)
    current = sink.get_body(notice_id)
    if text is None:
        if current is not None:
            sink.delete_body(notice_id)
        return
    if current is not None and current.get("body_text") == text:
        return
    sink.put_body({
        "notice_id": notice_id,
        "body_text": text,
        "notice_version": notice["notice_version"],
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })


def publish(notice: dict, issues: list[str], sink: NoticeSink, body: str | None = None) -> PublishOutcome:
    """검증을 통과한 published 공고만 공개한다.

    body는 이 공고의 수집 원문 본문. 새로 게시하거나 바뀐 공고만 서버 전용 저장소에 같이 쓰고, 공개본을 내릴 때 함께 지운다.
    공고가 바뀌지 않아 건너뛸 때(SKIPPED)는 본문을 읽지도 쓰지도 않는다(배치마다 읽기 수백 회를 아낌).
    이미 게시돼 있던 공고의 본문은 tools/upload_notice_bodies.py로 따로 올린다.

    새 버전의 분석이 실패하면 예전 공개본을 최신 검증 결과처럼 남기지 않도록 내리고 검토 대기로 보낸다.
    공고 삭제(lifecycle_status=removed)는 공개본에 상태로 남겨 저장 목록에서 보이게 한다.
    """
    issues = list(issues) + schema_errors("notice", notice)
    if issues or notice["publication_status"] != "published":
        sink.delete_public(notice["notice_id"])
        sink.put_review(notice, issues)
        return PublishOutcome.QUEUED

    current = sink.get_public(notice["notice_id"])
    if current and _same(current, notice):
        # 내용은 그대로여도 원문을 다시 확인한 시각은 공개본에 남긴다. 안 그러면 앱에 계속 '오래된 정보'로 보인다 (D-006)
        times = {k: notice[k] for k in _CHECK_TIMES if current.get(k) != notice[k]}
        if times:
            sink.touch_public(notice["notice_id"], times)
        return PublishOutcome.SKIPPED
    sink.put_public(notice)
    sink.delete_review(notice["notice_id"])
    sync_body(notice, body, sink)
    return PublishOutcome.PUBLISHED


_CHECK_TIMES = ("last_collected_at", "last_verified_at")


def _same(a: dict, b: dict) -> bool:
    keys = ("notice_version", "analysis_version", "lifecycle_status")
    # 알림톡의 관련 학교 공지는 원문·분석이 그대로여도 게시판 공고가 늘면 바뀐다 (D-025)
    return all(a[k] == b[k] for k in keys) and a.get("related_notices") == b.get("related_notices")
