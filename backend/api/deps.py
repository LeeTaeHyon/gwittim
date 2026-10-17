"""API가 쓰는 외부 경계: 토큰 검증, 저장소, 시계. 실제 구현(Firebase Admin·Firestore)은 Firebase 프로젝트 생성 후 추가한다."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Protocol

KST = timezone(timedelta(hours=9), "Asia/Seoul")


class TokenVerifier(Protocol):
    def verify(self, token: str) -> str | None:
        """유효하면 uid, 아니면 None. 사용자 ID는 이 결과로만 정한다 (SPEC §5)."""
        ...


class NoticeReader(Protocol):
    def get(self, notice_id: str) -> dict | None: ...
    def list_published(self) -> list[dict]: ...


class ProfileStore(Protocol):
    def get(self, uid: str) -> dict | None: ...
    def put(self, uid: str, profile: dict) -> None: ...
    def delete(self, uid: str) -> None: ...


class SavedStore(Protocol):
    def list(self, uid: str) -> list[dict]: ...
    def get(self, uid: str, notice_id: str) -> dict | None: ...
    def put(self, uid: str, saved: dict) -> None: ...
    def delete(self, uid: str, notice_id: str) -> None: ...
    def delete_all(self, uid: str) -> None: ...


class Clock(Protocol):
    def now(self) -> datetime: ...


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)


@dataclass
class FakeTokenVerifier:
    """테스트·로컬용: 토큰 문자열 → uid 표."""

    tokens: dict[str, str] = field(default_factory=dict)

    def verify(self, token: str) -> str | None:
        return self.tokens.get(token)


@dataclass
class InMemoryNotices:
    notices: dict[str, dict] = field(default_factory=dict)

    def get(self, notice_id):
        n = self.notices.get(notice_id)
        return n if n and n["publication_status"] == "published" else None

    def list_published(self):
        return [n for n in self.notices.values() if n["publication_status"] == "published"]


@dataclass
class InMemoryProfiles:
    profiles: dict[str, dict] = field(default_factory=dict)

    def get(self, uid):
        return self.profiles.get(uid)

    def put(self, uid, profile):
        self.profiles[uid] = profile

    def delete(self, uid):
        self.profiles.pop(uid, None)


@dataclass
class InMemorySaved:
    saved: dict[str, dict[str, dict]] = field(default_factory=dict)

    def list(self, uid):
        return sorted(self.saved.get(uid, {}).values(), key=lambda s: s["saved_at"], reverse=True)

    def get(self, uid, notice_id):
        return self.saved.get(uid, {}).get(notice_id)

    def put(self, uid, saved):
        self.saved.setdefault(uid, {})[saved["notice_id"]] = saved

    def delete(self, uid, notice_id):
        self.saved.get(uid, {}).pop(notice_id, None)

    def delete_all(self, uid):
        self.saved.pop(uid, None)


@dataclass
class Deps:
    verifier: TokenVerifier
    notices: NoticeReader
    profiles: ProfileStore
    saved: SavedStore
    clock: Clock = field(default_factory=SystemClock)

    def today_kst(self) -> date:
        return self.clock.now().astimezone(KST).date()

    def now_iso(self) -> str:
        return self.clock.now().astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
