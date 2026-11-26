"""API가 쓰는 외부 경계: 토큰 검증, 저장소, 시계. 실제 구현(Firebase Admin·Firestore)은 Firebase 프로젝트 생성 후 추가한다."""
from __future__ import annotations

import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Any, Protocol

from backend.agent.credits import CreditState

KST = timezone(timedelta(hours=9), "Asia/Seoul")


@dataclass(frozen=True)
class Caller:
    """토큰으로 확인한 요청자. guest는 Firebase 익명 계정(D-054). 저장하지 않고 요청마다 토큰에서 읽는다."""

    uid: str
    guest: bool = False


class TokenVerifier(Protocol):
    def verify_caller(self, token: str) -> Caller | None:
        """유효하면 요청자, 아니면 None. 사용자 ID는 이 결과로만 정한다 (SPEC §5)."""
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


class CreditStore(Protocol):
    def update(self, uid: str, fn: Callable[[CreditState | None], tuple[CreditState, Any]]) -> Any:
        """uid의 크레딧 상태를 읽고 → fn으로 계산하고 → 쓰는 일을 한 번에 한다(동시 요청 차단).

        fn은 (이전 상태 또는 None) -> (새 상태, 결과). 저장소가 재시도할 수 있으므로 fn은 부작용이 없어야 한다.
        """
        ...

    def delete(self, uid: str) -> None: ...


class ReportStore(Protocol):
    """AI 상세 분석 리포트 저장본. 문서 칸: notice_id, key, report, created_at, expires_at, request_id."""

    def put(self, uid: str, doc: dict) -> None: ...
    def get_by_key(self, uid: str, key: str) -> dict | None: ...
    def latest_for_notice(self, uid: str, notice_id: str, now: datetime) -> dict | None:
        """만료되지 않은 저장본 중 created_at이 가장 늦은 것."""
        ...

    def delete_all(self, uid: str) -> None: ...
    def delete_expired(self, now: datetime) -> int:
        """expires_at이 지난 저장본을 모든 사용자에 걸쳐 지우고 지운 개수를 돌려준다."""
        ...


class SharedNoticeStore(Protocol):
    """사용자가 카카오톡에서 넘긴 공고 (D-058). users/{uid}/shared_notices/{id}. 서버만 접근한다."""

    def put(self, uid: str, doc: dict) -> None: ...
    def list(self, uid: str) -> list[dict]:
        """created_at 내림차순(최근순)."""
        ...

    def count_since(self, uid: str, since_iso: str) -> int:
        """created_at이 since_iso(UTC 'Z' 형식) 이후인 항목 수."""
        ...

    def delete(self, uid: str, share_id: str) -> None: ...
    def delete_all(self, uid: str) -> None: ...


class SpendStore(Protocol):
    """LLM 비용 누적(원). 월 단위(KST 'YYYY-MM'). 사용자와 무관한 운영용 값이다 (D-039 월 상한)."""

    def add(self, month: str, krw: float) -> None:
        """동시 호출에도 안전하게 더한다."""
        ...

    def get(self, month: str) -> float: ...


class KakaoInbox(Protocol):
    def put(self, doc_id: str, doc: dict) -> bool: ...
    def list(self) -> list[dict]: ...


class Clock(Protocol):
    def now(self) -> datetime: ...


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)


@dataclass
class FakeTokenVerifier:
    """테스트·로컬용: 토큰 문자열 → uid 표. guest_tokens의 토큰은 게스트(익명 계정)로 본다."""

    tokens: dict[str, str] = field(default_factory=dict)
    guest_tokens: dict[str, str] = field(default_factory=dict)

    def verify_caller(self, token: str) -> Caller | None:
        if token in self.tokens:
            return Caller(self.tokens[token])
        if token in self.guest_tokens:
            return Caller(self.guest_tokens[token], guest=True)
        return None


@dataclass
class InMemoryNotices:
    notices: dict[str, dict] = field(default_factory=dict)

    def get(self, notice_id):
        n = self.notices.get(notice_id)
        return n if n and n["publication_status"] == "published" else None

    def list_published(self):
        return [n for n in self.notices.values() if n["publication_status"] == "published"]


class CachedNoticeReader:
    """공개 공고 목록을 짧게 캐시한다. 공고는 3시간마다 바뀌므로(D-006) 요청마다 전체를 읽지 않는다.

    list_recommendations가 매번 공개 공고 전체를 읽으면 Firestore 무료 읽기(일 5만)를 쉽게 넘는다
    (docs/cost-estimate.md). 단건 조회(get)는 캐시하지 않는다.
    """

    def __init__(self, inner: NoticeReader, ttl_seconds: float = 300.0, clock=None):
        import time

        self.inner = inner
        self.ttl = ttl_seconds
        self._now = clock or time.monotonic
        self._cached: list[dict] | None = None
        self._at = 0.0

    def get(self, notice_id):
        return self.inner.get(notice_id)

    def list_published(self):
        if self._cached is None or self._now() - self._at >= self.ttl:
            self._cached = self.inner.list_published()
            self._at = self._now()
        return self._cached


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
class InMemoryCredits:
    states: dict[str, CreditState] = field(default_factory=dict)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def update(self, uid, fn):
        with self._lock:
            new_state, result = fn(self.states.get(uid))
            self.states[uid] = new_state
            return result

    def delete(self, uid):
        with self._lock:
            self.states.pop(uid, None)


@dataclass
class InMemorySpend:
    months: dict[str, float] = field(default_factory=dict)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def add(self, month, krw):
        with self._lock:
            self.months[month] = self.months.get(month, 0.0) + krw

    def get(self, month):
        with self._lock:
            return self.months.get(month, 0.0)


@dataclass
class InMemoryReports:
    docs: dict[str, dict[str, dict]] = field(default_factory=dict)  # uid -> key -> doc

    def put(self, uid, doc):
        self.docs.setdefault(uid, {})[doc["key"]] = doc

    def get_by_key(self, uid, key):
        return self.docs.get(uid, {}).get(key)

    def latest_for_notice(self, uid, notice_id, now):
        live = [d for d in self.docs.get(uid, {}).values() if d["notice_id"] == notice_id and d["expires_at"] > now]
        return max(live, key=lambda d: d["created_at"], default=None)

    def delete_all(self, uid):
        self.docs.pop(uid, None)

    def delete_expired(self, now):
        removed = 0
        for uid, by_key in self.docs.items():
            for key in [k for k, d in by_key.items() if d["expires_at"] <= now]:
                del by_key[key]
                removed += 1
        return removed


@dataclass
class InMemorySharedNotices:
    docs: dict[str, dict[str, dict]] = field(default_factory=dict)  # uid -> id -> doc

    def put(self, uid, doc):
        self.docs.setdefault(uid, {})[doc["id"]] = doc

    def list(self, uid):
        return sorted(self.docs.get(uid, {}).values(), key=lambda d: d["created_at"], reverse=True)

    def count_since(self, uid, since_iso):
        return sum(1 for d in self.docs.get(uid, {}).values() if d["created_at"] >= since_iso)

    def delete(self, uid, share_id):
        self.docs.get(uid, {}).pop(share_id, None)

    def delete_all(self, uid):
        self.docs.pop(uid, None)


def delete_user_data(uid: str, *, saved: SavedStore, reports: ReportStore, credits: CreditStore,
                     profiles: ProfileStore, shared: SharedNoticeStore | None = None) -> None:
    """한 사용자의 서버 정보(저장·리포트·넘긴 공고·크레딧·프로필)를 지운다. DELETE /v1/profile과 게스트 정리 도구가 같이 쓴다."""
    saved.delete_all(uid)
    reports.delete_all(uid)
    if shared is not None:
        shared.delete_all(uid)
    credits.delete(uid)
    profiles.delete(uid)


@dataclass
class Deps:
    verifier: TokenVerifier
    notices: NoticeReader
    profiles: ProfileStore
    saved: SavedStore
    clock: Clock = field(default_factory=SystemClock)
    # 팀장 폰 수집기 (D-036). 둘 다 있어야 /v1/ingest/kakao가 열린다
    kakao_inbox: KakaoInbox | None = None
    ingest_token: str | None = None
    # AI 상세 분석(P7a). 제공자가 없으면 요청 때마다 GWITTIM_LLM_PROVIDER(기본 fake)로 만든다
    credits: CreditStore = field(default_factory=InMemoryCredits)
    reports: ReportStore = field(default_factory=InMemoryReports)
    llm: Any = None
    spend: SpendStore = field(default_factory=InMemorySpend)
    # 카카오톡에서 넘긴 공고 (D-058)
    shared: SharedNoticeStore = field(default_factory=InMemorySharedNotices)

    def today_kst(self) -> date:
        return self.clock.now().astimezone(KST).date()

    def month_kst(self) -> str:
        return self.clock.now().astimezone(KST).strftime("%Y-%m")

    def now_iso(self) -> str:
        return self.clock.now().astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
