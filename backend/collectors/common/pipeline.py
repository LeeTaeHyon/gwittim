"""수집 공통 파이프라인: 어댑터의 RawNotice를 받아 검증·중복 판정·버전 관리·실패 기록을 한다.

어댑터는 RawNotice 출력까지만 책임진다 (D-002). 분석·게시는 이 단계의 결과(new/changed)를 받아 W3·W4에서 처리한다.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum

from backend.contracts import schema_errors

from .identity import content_hash, notice_key
from .store import Failure, PipelineStore, RawRecord


class Outcome(str, Enum):
    NEW = "new"  # 처음 본 공고, notice_version 1
    CHANGED = "changed"  # 내용 변경, notice_version 증가
    UNCHANGED = "unchanged"  # 동일 내용, 확인 시각만 갱신
    REJECTED = "rejected"  # 검증 실패, 격리하고 기존 기록은 유지


@dataclass(frozen=True)
class Result:
    outcome: Outcome
    key: str | None
    notice_version: int | None
    errors: tuple[str, ...] = ()


def ingest(raw: dict, store: PipelineStore) -> Result:
    """RawNotice 하나를 처리한다. 예외 대신 Result로 결과를 돌려준다."""
    source_id = raw.get("source_id", "?") if isinstance(raw, dict) else "?"

    errors = schema_errors("raw_notice", raw)
    if errors:
        store.add_failure(Failure(at=_now_or(raw), source_id=source_id, stage="schema", reason="RawNotice 스키마 위반", detail=errors[:5]))
        return Result(Outcome.REJECTED, None, None, tuple(errors))

    key = notice_key(raw)
    expected = content_hash(raw)
    if raw["content_hash"] != expected:
        detail = [f"보고된 {raw['content_hash']}", f"계산된 {expected}"]
        store.add_failure(Failure(at=raw["collected_at"], source_id=source_id, stage="hash", reason="content_hash 불일치", key=key, detail=detail))
        return Result(Outcome.REJECTED, key, None, tuple(detail))

    existing = store.get(key)
    if existing is None:
        record = RawRecord(key, raw, expected, 1, raw["collected_at"], raw["collected_at"])
        outcome = Outcome.NEW
    elif existing.content_hash == expected:
        record = RawRecord(key, existing.raw, expected, existing.notice_version, existing.first_collected_at, raw["collected_at"])
        outcome = Outcome.UNCHANGED
    else:
        record = RawRecord(key, raw, expected, existing.notice_version + 1, existing.first_collected_at, raw["collected_at"])
        outcome = Outcome.CHANGED

    try:
        store.put(record)
    except OSError as e:
        store.add_failure(Failure(at=raw["collected_at"], source_id=source_id, stage="store", reason=type(e).__name__, key=key))
        return Result(Outcome.REJECTED, key, None, (type(e).__name__,))
    return Result(outcome, key, record.notice_version)


def ingest_batch(raws: list[dict], store: PipelineStore) -> list[Result]:
    """한 공고의 실패가 나머지 처리를 막지 않는다."""
    return [ingest(raw, store) for raw in raws]


def _now_or(raw) -> str:
    if isinstance(raw, dict) and isinstance(raw.get("collected_at"), str):
        return raw["collected_at"]
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
