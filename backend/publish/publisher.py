"""분석된 Notice를 게시 저장소에 반영한다 (W4, SPEC §6·§10).

컬렉션 구성 (firestore.rules와 같은 이름):
- notices/{notice_id}: 공개 공고. 앱은 로그인 사용자만 읽고, 쓰기는 서버만
- review_queue/{notice_id}: 검증 실패·검토 대기 (비공개)
- users/{uid}, users/{uid}/saved/{notice_id}: 본인만 읽기, 쓰기는 서버 API(W13)
- raw_notices, pipeline_failures: 원문 수집 자료·실패 기록 (비공개, 파이프라인 저장소)

Firestore 구현은 Firebase 프로젝트 생성 후 같은 인터페이스로 추가한다.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Protocol

from backend.contracts import schema_errors

NOTICES = "notices"
REVIEW_QUEUE = "review_queue"
USERS = "users"
SAVED = "saved"
RAW_NOTICES = "raw_notices"
PIPELINE_FAILURES = "pipeline_failures"


class PublishOutcome(str, Enum):
    PUBLISHED = "published"  # 공개 컬렉션에 쓰기
    QUEUED = "queued"  # 검토 대기로 보내고 공개본은 내림
    SKIPPED = "skipped"  # 공개본과 같은 버전·분석이면 다시 쓰지 않음


class NoticeSink(Protocol):
    def get_public(self, notice_id: str) -> dict | None: ...
    def put_public(self, notice: dict) -> None: ...
    def delete_public(self, notice_id: str) -> None: ...
    def put_review(self, notice: dict, issues: list[str]) -> None: ...
    def delete_review(self, notice_id: str) -> None: ...


@dataclass
class InMemorySink:
    public: dict[str, dict] = field(default_factory=dict)
    review: dict[str, dict] = field(default_factory=dict)

    def get_public(self, notice_id):
        return self.public.get(notice_id)

    def put_public(self, notice):
        self.public[notice["notice_id"]] = notice

    def delete_public(self, notice_id):
        self.public.pop(notice_id, None)

    def put_review(self, notice, issues):
        self.review[notice["notice_id"]] = {"notice": notice, "issues": issues}

    def delete_review(self, notice_id):
        self.review.pop(notice_id, None)


def publish(notice: dict, issues: list[str], sink: NoticeSink) -> PublishOutcome:
    """검증을 통과한 published 공고만 공개한다.

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
        return PublishOutcome.SKIPPED
    sink.put_public(notice)
    sink.delete_review(notice["notice_id"])
    return PublishOutcome.PUBLISHED


def _same(a: dict, b: dict) -> bool:
    keys = ("notice_version", "analysis_version", "lifecycle_status")
    # 알림톡의 관련 학교 공지는 원문·분석이 그대로여도 게시판 공고가 늘면 바뀐다 (D-025)
    return all(a[k] == b[k] for k in keys) and a.get("related_notices") == b.get("related_notices")
