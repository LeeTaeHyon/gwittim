"""교외 분석 대기열: 수집 단계가 넣고 분석 단계(analyze_queue)가 꺼낸다.

파일 data/local/analysis_queue.json에 배치 사이에도 남는다. 항목은 공고 키마다 한 건이고
{source_id, key, queued_at(UTC), reason(new|changed|recovered|llm_fallback)}를 가진다. 같은 키가 다시 들어오면 합치고 넣은 시각은 처음 값을 유지한다.
처리 순서는 D-048 출처 우선순위 안에서 오래 기다린 순이다(우선 출처가 먼저 분석돼야 뒤 출처의 같은 공고가 처음부터 중복으로 묶인다).
파일이 없거나 깨졌으면 빈 대기열로 시작하고, 깨진 파일은 .broken으로 옮겨 둔다.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from backend.analysis.external_match import EXTERNAL_PRIORITY

from .pipeline import Outcome, ingest
from .store import PipelineStore

QUEUE_FILE = "analysis_queue.json"
REASONS = ("new", "changed", "recovered", "llm_fallback")  # recovered: 원문 기록은 있는데 분석 결과가 없는 공고를 다시 넣음


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _priority(source_id: str) -> int:
    return EXTERNAL_PRIORITY.index(source_id) if source_id in EXTERNAL_PRIORITY else len(EXTERNAL_PRIORITY)


class AnalysisQueue:
    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path else None
        self.entries: dict[str, dict] = {}
        self.load_error: str | None = None
        if self.path is not None:
            self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            entries = {}
            for item in data["items"]:
                entries[item["key"]] = {
                    "source_id": str(item["source_id"]),
                    "key": str(item["key"]),
                    "queued_at": str(item["queued_at"]),
                    "reason": str(item.get("reason", "new")),
                }
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            self.load_error = type(e).__name__
            try:
                self.path.replace(self.path.with_name(self.path.name + ".broken"))
            except OSError:
                pass
            return
        self.entries = entries

    def __len__(self) -> int:
        return len(self.entries)

    def __contains__(self, key: str) -> bool:
        return key in self.entries

    def add(self, source_id: str, key: str, reason: str, queued_at: str | None = None) -> bool:
        """새로 넣으면 True, 이미 있어 합치면 False."""
        if key in self.entries:
            return False
        self.entries[key] = {"source_id": source_id, "key": key, "queued_at": queued_at or utc_now(), "reason": reason}
        return True

    def remove(self, key: str) -> None:
        self.entries.pop(key, None)

    def ordered(self) -> list[dict]:
        """출처 우선순위, 그 안에서 오래 기다린 순(같으면 키 순)."""
        return sorted(self.entries.values(), key=lambda e: (_priority(e["source_id"]), e["queued_at"], e["key"]))

    def remaining_by_source(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for e in self.entries.values():
            out[e["source_id"]] = out.get(e["source_id"], 0) + 1
        return dict(sorted(out.items(), key=lambda kv: _priority(kv[0])))

    def oldest_wait_minutes(self, now: datetime | None = None) -> float | None:
        if not self.entries:
            return None
        now = now or datetime.now(timezone.utc)
        waits = []
        for e in self.entries.values():
            try:
                at = datetime.strptime(e["queued_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            except ValueError:
                continue
            waits.append((now - at).total_seconds() / 60)
        return round(max(waits), 1) if waits else None

    def save(self) -> None:
        if self.path is None:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"items": self.ordered()}, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(self.path)


def collect_to_queue(
    raws,
    *,
    source_id: str,
    store: PipelineStore,
    queue: AnalysisQueue,
    notices: dict[str, dict],
) -> dict:
    """수집 단계: RawNotice를 파이프라인에 저장(new/changed/unchanged 판정)하고 new·changed만 대기열에 넣는다. 분석은 하지 않는다.

    복구: 원문 기록은 있는데 분석 결과(notices)도 대기열 항목도 없는 공고(예: 대기열 파일이 깨졌을 때)는 recovered로 다시 넣는다.
    어댑터는 이미 아는 공고의 상세를 열지 않으므로, 이렇게 하지 않으면 영영 분석되지 않는다.
    """
    counts = {o.value: 0 for o in Outcome}
    queued = 0
    seen: set[str] = set()
    for raw in raws:
        result = ingest(raw, store)
        counts[result.outcome.value] += 1
        if result.key is None or result.outcome is Outcome.REJECTED:
            continue
        seen.add(result.key)
        if result.outcome in (Outcome.NEW, Outcome.CHANGED):
            queued += queue.add(source_id, result.key, result.outcome.value)
    recovered = 0
    prefix = source_id + ":"
    for key, record in list(getattr(store, "records", {}).items()):
        if key.startswith(prefix) and not record.removed and key not in notices and key not in queue:
            recovered += queue.add(source_id, key, "recovered")
    return {"outcomes": counts, "queued": queued, "recovered": recovered}
