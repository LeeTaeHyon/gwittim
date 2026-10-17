import copy
import json
from pathlib import Path

import pytest

from backend.collectors.common import (
    InMemoryStore,
    JsonFileStore,
    Outcome,
    content_hash,
    ingest,
    ingest_batch,
    normalize_url,
    notice_key,
)

FIXTURE = Path(__file__).resolve().parents[4] / "fixtures/valid/raw_notice/mjc_board_date_only.json"


def make_raw(**changes) -> dict:
    raw = json.loads(FIXTURE.read_text(encoding="utf-8"))
    raw.update(changes)
    raw["content_hash"] = content_hash(raw)
    return raw


def test_new_notice_gets_version_1():
    store = InMemoryStore()
    result = ingest(make_raw(), store)
    assert result.outcome is Outcome.NEW
    assert result.notice_version == 1
    assert len(store.records) == 1


def test_same_content_recollected_is_not_duplicated():
    store = InMemoryStore()
    ingest(make_raw(), store)
    result = ingest(make_raw(collected_at="2026-10-17T06:00:00Z"), store)
    assert result.outcome is Outcome.UNCHANGED
    assert result.notice_version == 1
    assert len(store.records) == 1
    record = store.records[result.key]
    assert record.first_collected_at == "2026-10-17T03:00:00Z"
    assert record.last_collected_at == "2026-10-17T06:00:00Z"


def test_collected_at_does_not_affect_hash():
    assert content_hash(make_raw()) == content_hash(make_raw(collected_at="2027-01-01T00:00:00Z"))


def test_changed_content_increments_version_and_keeps_first_seen():
    store = InMemoryStore()
    ingest(make_raw(), store)
    changed = make_raw(body_text="신청기간: 2026.10.20.(화) ~ 2026.11.09.(월)", collected_at="2026-10-18T03:00:00Z")
    result = ingest(changed, store)
    assert result.outcome is Outcome.CHANGED
    assert result.notice_version == 2
    record = store.records[result.key]
    assert record.raw["body_text"].endswith("11.09.(월)")
    assert record.first_collected_at == "2026-10-17T03:00:00Z"


def test_schema_violation_is_quarantined_and_existing_kept():
    store = InMemoryStore()
    ingest(make_raw(), store)
    bad = make_raw(collected_at="2026-10-18T12:00:00+09:00")
    result = ingest(bad, store)
    assert result.outcome is Outcome.REJECTED
    assert store.failures[-1].stage == "schema"
    assert next(iter(store.records.values())).notice_version == 1


def test_wrong_content_hash_is_rejected():
    store = InMemoryStore()
    raw = make_raw()
    raw["content_hash"] = "sha256:" + "0" * 64
    result = ingest(raw, store)
    assert result.outcome is Outcome.REJECTED
    assert store.failures[-1].stage == "hash"
    assert not store.records


def test_batch_continues_after_failure():
    store = InMemoryStore()
    bad = make_raw()
    del bad["title"]
    results = ingest_batch([bad, make_raw()], store)
    assert [r.outcome for r in results] == [Outcome.REJECTED, Outcome.NEW]


def test_key_falls_back_to_normalized_url():
    raw = make_raw(source_notice_id=None, source_url="HTTPS://Example.invalid/n?b=2&a=1#top")
    assert notice_key(raw) == "mjc_www_notice:url:https://example.invalid/n?a=1&b=2"
    assert normalize_url("https://example.invalid/n?a=1&b=2") == normalize_url("https://EXAMPLE.invalid/n?b=2&a=1")


@pytest.mark.parametrize("field", ["title", "published", "source_fields"])
def test_meaningful_fields_change_hash(field):
    base = make_raw()
    changed = copy.deepcopy(base)
    changed[field] = {"title": "다른 제목", "published": None, "source_fields": {"author_department": "다른 부서"}}[field]
    assert content_hash(base) != content_hash(changed)


def test_json_file_store_persists(tmp_path):
    store = JsonFileStore(tmp_path)
    ingest(make_raw(), store)
    bad = make_raw()
    bad["content_hash"] = "sha256:" + "0" * 64
    ingest(bad, store)

    reopened = JsonFileStore(tmp_path)
    assert len(reopened.records) == 1
    assert ingest(make_raw(), reopened).outcome is Outcome.UNCHANGED
    assert (tmp_path / "failures.jsonl").read_text(encoding="utf-8").count("\n") == 1
