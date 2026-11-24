"""Firebase Admin 구현: 서버 API(W13)의 저장소·토큰 검증과 게시(W4)의 NoticeSink.

- 로컬: FIRESTORE_EMULATOR_HOST / FIREBASE_AUTH_EMULATOR_HOST가 있으면 에뮬레이터에 붙는다(demo-* 프로젝트).
- Cloud Run: 서비스 계정 기본 인증(ADC)을 쓴다. 키 파일을 저장소에 두지 않는다 (SPEC §10).
컬렉션 이름은 backend/publish 와 firestore.rules 와 같다.
"""
from __future__ import annotations

import os
from datetime import date, datetime

import firebase_admin
from firebase_admin import auth, credentials, firestore
from google.auth.credentials import AnonymousCredentials

from backend.agent.credits import CreditState, Hold, LedgerEntry
from backend.publish import NOTICE_BODIES, NOTICES, REVIEW_QUEUE, SAVED, USERS
from backend.collectors.mjc_kakao.inbox import INBOX as KAKAO_INBOX

_PROFILE_FIELDS = ("university_id", "major_id", "grade", "enrollment_status", "interest_ids", "target_role_ids", "updated_at", "agent_consent")


class _EmulatorCredential(credentials.Base):
    """에뮬레이터 전용: 실제 Google 자격 증명 없이 접속한다."""

    def get_credential(self):
        return AnonymousCredentials()


def _using_emulator() -> bool:
    return bool(os.environ.get("FIRESTORE_EMULATOR_HOST") or os.environ.get("FIREBASE_AUTH_EMULATOR_HOST"))


def init_app(project_id: str, name: str = "[DEFAULT]") -> firebase_admin.App:
    try:
        return firebase_admin.get_app(name)
    except ValueError:
        cred = _EmulatorCredential() if _using_emulator() else None  # Cloud Run에서는 서비스 계정 ADC
        return firebase_admin.initialize_app(cred, options={"projectId": project_id}, name=name)


class FirebaseTokenVerifier:
    def __init__(self, app: firebase_admin.App):
        self.app = app

    def verify(self, token: str) -> str | None:
        try:
            return auth.verify_id_token(token, app=self.app)["uid"]
        except (ValueError, auth.InvalidIdTokenError, auth.ExpiredIdTokenError, auth.RevokedIdTokenError, auth.CertificateFetchError):
            return None


class _Base:
    def __init__(self, app: firebase_admin.App):
        self.db = firestore.client(app)


class FirestoreNotices(_Base):
    """NoticeReader: published 공고만 돌려준다."""

    def get(self, notice_id):
        snap = self.db.collection(NOTICES).document(notice_id).get()
        data = snap.to_dict() if snap.exists else None
        return data if data and data.get("publication_status") == "published" else None

    def list_published(self):
        query = self.db.collection(NOTICES).where(filter=firestore.FieldFilter("publication_status", "==", "published"))
        return [d.to_dict() for d in query.stream()]


class FirestoreProfiles(_Base):
    """users/{uid} 문서에 프로필 필드를 둔다."""

    def get(self, uid):
        snap = self.db.collection(USERS).document(uid).get()
        if not snap.exists:
            return None
        data = snap.to_dict()
        return {k: data[k] for k in _PROFILE_FIELDS if k in data} if "updated_at" in data else None

    def put(self, uid, profile):
        self.db.collection(USERS).document(uid).set(profile)

    def delete(self, uid):
        self.db.collection(USERS).document(uid).delete()


class FirestoreSaved(_Base):
    """users/{uid}/saved/{notice_id}"""

    def _col(self, uid):
        return self.db.collection(USERS).document(uid).collection(SAVED)

    def list(self, uid):
        return sorted((d.to_dict() for d in self._col(uid).stream()), key=lambda s: s["saved_at"], reverse=True)

    def get(self, uid, notice_id):
        snap = self._col(uid).document(notice_id).get()
        return snap.to_dict() if snap.exists else None

    def put(self, uid, saved):
        self._col(uid).document(saved["notice_id"]).set(saved)

    def delete(self, uid, notice_id):
        self._col(uid).document(notice_id).delete()

    def delete_all(self, uid):
        for doc in self._col(uid).list_documents():
            doc.delete()


CREDITS = "credits"  # users/{uid}/credits/state (문서 하나)
AGENT_REPORTS = "agent_reports"  # users/{uid}/agent_reports/{key}. 탈퇴 때 사용자 아래라 지우기 쉽고, 만료 삭제는 collection group 쿼리


def _credit_state_to_dict(state: CreditState) -> dict:
    """datetime·date는 ISO 문자열로 저장한다."""
    return {
        "balance": state.balance,
        "last_charge_date": state.last_charge_date.isoformat(),
        "processed": [{"request_id": rid, "at": at.isoformat()} for rid, at in state.processed],
        "entries": [{"kind": e.kind, "amount": e.amount, "at": e.at.isoformat(), "ref": e.ref} for e in state.entries],
        "holds": [{"request_id": h.request_id, "kind": h.kind, "cost": h.cost, "at": h.at.isoformat()} for h in state.holds],
    }


def _credit_state_from_dict(data: dict) -> CreditState:
    return CreditState(
        balance=data["balance"],
        last_charge_date=date.fromisoformat(data["last_charge_date"]),
        processed=tuple((p["request_id"], datetime.fromisoformat(p["at"])) for p in data.get("processed", [])),
        entries=tuple(
            LedgerEntry(e["kind"], e["amount"], datetime.fromisoformat(e["at"]), e.get("ref")) for e in data.get("entries", [])
        ),
        holds=tuple(
            Hold(h["request_id"], h["kind"], h["cost"], datetime.fromisoformat(h["at"])) for h in data.get("holds", [])
        ),
    )


class FirestoreCredits(_Base):
    """users/{uid}/credits/state. 읽기·계산·쓰기를 트랜잭션 하나로 묶어 동시 요청(연타)을 막는다."""

    def _ref(self, uid):
        return self.db.collection(USERS).document(uid).collection(CREDITS).document("state")

    def update(self, uid, fn):
        ref = self._ref(uid)

        @firestore.transactional
        def run(transaction):
            snap = ref.get(transaction=transaction)
            state = _credit_state_from_dict(snap.to_dict()) if snap.exists else None
            new_state, result = fn(state)  # 트랜잭션이 재시도되면 다시 불리므로 fn은 부작용이 없어야 한다
            transaction.set(ref, _credit_state_to_dict(new_state))
            return result

        return run(self.db.transaction())

    def delete(self, uid):
        self._ref(uid).delete()


class FirestoreReports(_Base):
    """users/{uid}/agent_reports/{key}. created_at·expires_at은 Firestore 시각 값으로 저장한다(범위 쿼리용)."""

    def _col(self, uid):
        return self.db.collection(USERS).document(uid).collection(AGENT_REPORTS)

    def put(self, uid, doc):
        self._col(uid).document(doc["key"]).set(doc)

    def get_by_key(self, uid, key):
        snap = self._col(uid).document(key).get()
        return snap.to_dict() if snap.exists else None

    def latest_for_notice(self, uid, notice_id, now):
        # 한 공고에 저장본은 몇 개뿐이라 등호 조건 하나로 읽고 만료·최신은 여기서 가린다(복합 색인 불필요)
        query = self._col(uid).where(filter=firestore.FieldFilter("notice_id", "==", notice_id))
        live = [d for d in (s.to_dict() for s in query.stream()) if d["expires_at"] > now]
        return max(live, key=lambda d: d["created_at"], default=None)

    def delete_all(self, uid):
        for doc in self._col(uid).list_documents():
            doc.delete()

    def delete_expired(self, now):
        # collection group 쿼리: expires_at 단일 필드 색인을 컬렉션 그룹 범위로 켜 두어야 한다(배포 때 설정)
        query = self.db.collection_group(AGENT_REPORTS).where(filter=firestore.FieldFilter("expires_at", "<=", now))
        removed = 0
        for snap in query.stream():
            snap.reference.delete()
            removed += 1
        return removed


SPEND_COLLECTION = "ops"  # ops/llm_spend_YYYY-MM. 사용자 데이터와 분리한 운영용 문서(보안 규칙 기본값으로 클라이언트 접근 차단)


def _spend_doc_id(month: str) -> str:
    return f"llm_spend_{month}"


class FirestoreSpend(_Base):
    """월별 LLM 비용 누적(원). Increment로 더해 동시 호출에도 값이 유실되지 않는다."""

    def _ref(self, month):
        return self.db.collection(SPEND_COLLECTION).document(_spend_doc_id(month))

    def add(self, month, krw):
        self._ref(month).set({"month": month, "krw": firestore.Increment(krw)}, merge=True)

    def get(self, month):
        snap = self._ref(month).get()
        data = snap.to_dict() if snap.exists else None
        value = (data or {}).get("krw", 0)
        return float(value) if isinstance(value, (int, float)) else 0.0


class FirestoreSink(_Base):
    """NoticeSink: 공개 공고와 검토 대기."""

    def get_public(self, notice_id):
        snap = self.db.collection(NOTICES).document(notice_id).get()
        return snap.to_dict() if snap.exists else None

    def put_public(self, notice):
        self.db.collection(NOTICES).document(notice["notice_id"]).set(notice)

    def delete_public(self, notice_id):
        self.db.collection(NOTICES).document(notice_id).delete()
        self.delete_body(notice_id)  # 공개본을 내리면 본문도 함께 지운다

    def touch_public(self, notice_id, fields):
        self.db.collection(NOTICES).document(notice_id).update(fields)

    def put_review(self, notice, issues):
        self.db.collection(REVIEW_QUEUE).document(notice["notice_id"]).set({"notice": notice, "issues": issues})

    def delete_review(self, notice_id):
        self.db.collection(REVIEW_QUEUE).document(notice_id).delete()

    # notice_bodies/{notice_id}: 서버 전용. firestore.rules가 앱 접근을 막는다
    def get_body(self, notice_id):
        snap = self.db.collection(NOTICE_BODIES).document(notice_id).get()
        return snap.to_dict() if snap.exists else None

    def put_body(self, doc):
        self.db.collection(NOTICE_BODIES).document(doc["notice_id"]).set(doc)

    def delete_body(self, notice_id):
        self.db.collection(NOTICE_BODIES).document(notice_id).delete()


class FirestoreBodies(_Base):
    """BodyReader: 상세 분석 요청 때만 본문 1건을 읽는다. 없으면 None."""

    def get(self, notice_id):
        snap = self.db.collection(NOTICE_BODIES).document(notice_id).get()
        text = (snap.to_dict() or {}).get("body_text") if snap.exists else None
        return text if isinstance(text, str) and text.strip() else None


class FirestoreKakaoInbox(_Base):
    """팀장 폰 수집기가 올린 알림톡 받은편지함 (D-036). 클라이언트 접근은 보안 규칙의 기본값으로 막힌다."""

    def put(self, doc_id, doc):
        from google.api_core.exceptions import AlreadyExists, Conflict

        try:
            self.db.collection(KAKAO_INBOX).document(doc_id).create(doc)  # 같은 알림을 다시 올리면 처음 것을 둔다
        except (AlreadyExists, Conflict):
            return False
        return True

    def list(self):
        return [snap.to_dict() for snap in self.db.collection(KAKAO_INBOX).stream()]
