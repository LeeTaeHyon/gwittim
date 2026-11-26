"""만든 지 30일이 지난 게스트(Firebase 익명 계정)를 지운다 (D-054, docs/guest-login-spec.md §5).

팀장이 자기 PC에서 손으로 실행한다. 예약 작업은 두지 않는다.
먼저 `gcloud auth application-default login`으로 ADC 로그인.

    uv run python -m tools.cleanup_guests            # 건조 실행: 대상 수만 출력
    uv run python -m tools.cleanup_guests --apply    # 실제 삭제: 서버 정보 → Auth 계정 순서

출력에는 uid·개인정보를 찍지 않는다(건수와 실패 수만).
"""
from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

RETENTION = timedelta(days=30)
DEFAULT_PROJECT = "gwittim-dev"


@dataclass(frozen=True)
class Account:
    uid: str
    anonymous: bool  # 로그인 제공자가 하나도 없음 = 익명 계정
    created_at: datetime | None  # 만든 시각(UTC). 모르면 None → 대상에서 뺌


@dataclass(frozen=True)
class Result:
    targets: int
    deleted: int = 0
    failed: int = 0


def select_targets(accounts: Iterable[Account], now: datetime, retention: timedelta = RETENTION) -> list[str]:
    """익명 계정이면서 만든 지 retention 이상 지난 것의 uid. 만든 시각을 모르면 지우지 않는다."""
    return [
        a.uid
        for a in accounts
        if a.anonymous and a.created_at is not None and now - a.created_at >= retention
    ]


def cleanup(
    uids: list[str],
    delete_data: Callable[[str], None],
    delete_account: Callable[[str], None],
    apply: bool,
) -> Result:
    """apply면 한 사람씩 서버 정보 → Auth 계정 순서로 지운다.

    서버 정보 삭제가 실패하면 계정은 남겨 둔다(다음 실행 때 다시 대상이 된다).
    """
    if not apply:
        return Result(targets=len(uids))
    deleted = failed = 0
    for uid in uids:
        try:
            delete_data(uid)
            delete_account(uid)
            deleted += 1
        except Exception:  # 어느 계정이 왜 실패했는지는 찍지 않는다(uid 출력 금지)
            failed += 1
    return Result(targets=len(uids), deleted=deleted, failed=failed)


def _firebase_accounts(app) -> Iterable[Account]:
    from firebase_admin import auth

    for user in auth.list_users(app=app).iterate_all():
        created_ms = user.user_metadata.creation_timestamp if user.user_metadata else None
        created = datetime.fromtimestamp(created_ms / 1000, timezone.utc) if created_ms else None
        yield Account(uid=user.uid, anonymous=not user.provider_data, created_at=created)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="30일 지난 게스트 계정 정리")
    parser.add_argument("--apply", action="store_true", help="실제로 지운다(없으면 대상 수만 출력)")
    parser.add_argument("--project", default=os.environ.get("GWITTIM_FIREBASE_PROJECT_ID", DEFAULT_PROJECT))
    args = parser.parse_args(argv)

    from firebase_admin import auth

    from backend.api.deps import delete_user_data
    from backend.firebase_store import (
        FirestoreCredits,
        FirestoreProfiles,
        FirestoreReports,
        FirestoreSaved,
        FirestoreSharedNotices,
        init_app,
    )

    app = init_app(args.project, name="cleanup-guests")
    stores = {
        "saved": FirestoreSaved(app),
        "reports": FirestoreReports(app),
        "credits": FirestoreCredits(app),
        "profiles": FirestoreProfiles(app),
        "shared": FirestoreSharedNotices(app),
    }
    uids = select_targets(_firebase_accounts(app), datetime.now(timezone.utc))
    result = cleanup(
        uids,
        delete_data=lambda uid: delete_user_data(uid, **stores),
        delete_account=lambda uid: auth.delete_user(uid, app=app),
        apply=args.apply,
    )
    if args.apply:
        print(f"대상 {result.targets}건, 삭제 {result.deleted}건, 실패 {result.failed}건")
    else:
        print(f"대상 {result.targets}건 (건조 실행, 지우려면 --apply)")
    return 1 if result.failed else 0


if __name__ == "__main__":
    sys.exit(main())
