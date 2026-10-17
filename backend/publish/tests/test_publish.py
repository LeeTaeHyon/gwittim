import copy
import json
from pathlib import Path

from backend.publish import InMemorySink, PublishOutcome, publish

ROOT = Path(__file__).resolve().parents[3]


def notice() -> dict:
    return json.loads((ROOT / "fixtures/valid/notice/date_only_timezone_unknown.json").read_text(encoding="utf-8"))


def test_published_notice_goes_public():
    sink = InMemorySink()
    assert publish(notice(), [], sink) is PublishOutcome.PUBLISHED
    assert list(sink.public) == ["n_synthetic_0001"] and not sink.review


def test_same_version_is_skipped():
    sink = InMemorySink()
    publish(notice(), [], sink)
    assert publish(notice(), [], sink) is PublishOutcome.SKIPPED


def test_review_pending_never_public():
    sink = InMemorySink()
    n = notice()
    n["publication_status"] = "review_pending"
    assert publish(n, ["application_start가 마감보다 늦음"], sink) is PublishOutcome.QUEUED
    assert not sink.public
    assert sink.review["n_synthetic_0001"]["issues"] == ["application_start가 마감보다 늦음"]


def test_failed_new_version_takes_old_public_copy_down():
    sink = InMemorySink()
    publish(notice(), [], sink)
    v2 = notice()
    v2.update(notice_version=2, publication_status="review_pending")
    assert publish(v2, ["원문에 없는 근거"], sink) is PublishOutcome.QUEUED
    assert "n_synthetic_0001" not in sink.public


def test_recovered_version_leaves_review_queue():
    sink = InMemorySink()
    bad = notice()
    bad["publication_status"] = "review_pending"
    publish(bad, ["x"], sink)
    fixed = notice()
    fixed["notice_version"] = 2
    assert publish(fixed, [], sink) is PublishOutcome.PUBLISHED
    assert not sink.review


def test_schema_invalid_is_queued_even_if_marked_published():
    sink = InMemorySink()
    n = copy.deepcopy(notice())
    n["category"] = "Not A Code"
    assert publish(n, [], sink) is PublishOutcome.QUEUED
    assert not sink.public


def test_removed_notice_stays_public_with_status():
    sink = InMemorySink()
    publish(notice(), [], sink)
    removed = notice()
    removed["lifecycle_status"] = "removed"
    assert publish(removed, [], sink) is PublishOutcome.PUBLISHED
    assert sink.public["n_synthetic_0001"]["lifecycle_status"] == "removed"
