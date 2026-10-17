"""파이프라인 저장소 인터페이스와 로컬 구현.

실제 Firestore 구현은 W4에서 같은 인터페이스로 추가한다. 원문 수집 자료와 실패 기록은
공개 컬렉션과 분리된 저장소에 둔다 (SPEC §10).
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Protocol


@dataclass
class RawRecord:
    key: str
    raw: dict
    content_hash: str
    notice_version: int
    first_collected_at: str
    last_collected_at: str
    consecutive_not_found: int = 0  # D-006: 서로 다른 수집 실행에서 연속으로 원문이 없던 횟수
    removed: bool = False


@dataclass
class Failure:
    at: str
    source_id: str
    stage: str  # schema | hash | store
    reason: str
    key: str | None = None
    detail: list[str] = field(default_factory=list)


class PipelineStore(Protocol):
    def get(self, key: str) -> RawRecord | None: ...
    def put(self, record: RawRecord) -> None: ...
    def add_failure(self, failure: Failure) -> None: ...


class InMemoryStore:
    def __init__(self) -> None:
        self.records: dict[str, RawRecord] = {}
        self.failures: list[Failure] = []

    def get(self, key: str) -> RawRecord | None:
        return self.records.get(key)

    def put(self, record: RawRecord) -> None:
        self.records[record.key] = record

    def add_failure(self, failure: Failure) -> None:
        self.failures.append(failure)


class JsonFileStore(InMemoryStore):
    """팀장 PC 로컬 배치용. 디렉터리 하나에 records.json·failures.jsonl을 둔다. 저장소에 커밋하지 않는다."""

    def __init__(self, directory: Path) -> None:
        super().__init__()
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self._records_path = self.directory / "records.json"
        self._failures_path = self.directory / "failures.jsonl"
        if self._records_path.exists():
            data = json.loads(self._records_path.read_text(encoding="utf-8"))
            self.records = {k: RawRecord(**v) for k, v in data.items()}

    def put(self, record: RawRecord) -> None:
        super().put(record)
        tmp = self._records_path.with_suffix(".tmp")
        tmp.write_text(
            json.dumps({k: asdict(v) for k, v in self.records.items()}, ensure_ascii=False, indent=1),
            encoding="utf-8",
        )
        tmp.replace(self._records_path)

    def add_failure(self, failure: Failure) -> None:
        super().add_failure(failure)
        with self._failures_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(asdict(failure), ensure_ascii=False) + "\n")
