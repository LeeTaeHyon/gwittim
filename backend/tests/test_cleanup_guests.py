"""게스트 30일 정리 도구 (D-054). 가짜 저장소·가짜 사용자 목록만 쓴다."""
from datetime import datetime, timedelta, timezone

from backend.agent.credits import signup
from backend.api.deps import (
    InMemoryCredits,
    InMemoryProfiles,
    InMemoryReports,
    InMemorySaved,
    InMemorySharedNotices,
    delete_user_data,
)
from tools.cleanup_guests import Account, cleanup, select_targets

NOW = datetime(2026, 12, 31, 12, 0, tzinfo=timezone.utc)


def test_select_only_old_anonymous_accounts():
    accounts = [
        Account("old-guest", anonymous=True, created_at=NOW - timedelta(days=30)),
        Account("older-guest", anonymous=True, created_at=NOW - timedelta(days=45)),
        Account("new-guest", anonymous=True, created_at=NOW - timedelta(days=29, hours=23)),
        Account("old-google", anonymous=False, created_at=NOW - timedelta(days=90)),
        Account("unknown-age", anonymous=True, created_at=None),
    ]
    assert select_targets(accounts, NOW) == ["old-guest", "older-guest"]


def test_dry_run_deletes_nothing():
    calls = []
    result = cleanup(["a", "b"], calls.append, calls.append, apply=False)
    assert result.targets == 2 and result.deleted == 0 and result.failed == 0
    assert calls == []


def test_apply_deletes_data_then_account_with_same_scope_as_profile_delete():
    stores = {
        "saved": InMemorySaved(),
        "reports": InMemoryReports(),
        "credits": InMemoryCredits(),
        "profiles": InMemoryProfiles(),
        "shared": InMemorySharedNotices(),
    }
    for uid in ("g1", "keep"):
        stores["profiles"].put(uid, {"major_id": None})
        stores["saved"].put(uid, {"notice_id": "n1"})
        stores["shared"].put(uid, {"id": "s1", "created_at": "2026-12-01T00:00:00Z"})
        stores["credits"].update(uid, lambda s: (signup(NOW, guest=True), None))
        stores["reports"].put(uid, {"key": "k", "notice_id": "n1", "expires_at": NOW, "created_at": NOW})
    order = []

    def delete_data(uid):
        order.append(("data", uid))
        delete_user_data(uid, **stores)

    result = cleanup(["g1"], delete_data, lambda uid: order.append(("account", uid)), apply=True)
    assert result.deleted == 1 and result.failed == 0
    assert order == [("data", "g1"), ("account", "g1")]
    assert stores["profiles"].get("g1") is None
    assert stores["saved"].list("g1") == []
    assert "g1" not in stores["credits"].states
    assert "g1" not in stores["reports"].docs
    assert "g1" not in stores["shared"].docs and "keep" in stores["shared"].docs
    assert stores["profiles"].get("keep") is not None  # 다른 사람은 그대로


def test_data_failure_keeps_account_and_counts():
    accounts_deleted = []

    def delete_data(uid):
        if uid == "bad":
            raise RuntimeError("firestore down")

    result = cleanup(["ok", "bad"], delete_data, accounts_deleted.append, apply=True)
    assert (result.targets, result.deleted, result.failed) == (2, 1, 1)
    assert accounts_deleted == ["ok"]  # 서버 정보를 못 지운 계정은 남긴다
