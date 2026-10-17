"""Firebase Admin 구현: 서버 API(W13)의 저장소·토큰 검증과 게시(W4)의 NoticeSink.

- 로컬: FIRESTORE_EMULATOR_HOST / FIREBASE_AUTH_EMULATOR_HOST가 있으면 에뮬레이터에 붙는다(demo-* 프로젝트).
- Cloud Run: 서비스 계정 기본 인증(ADC)을 쓴다. 키 파일을 저장소에 두지 않는다 (SPEC §10).
컬렉션 이름은 backend/publish 와 firestore.rules 와 같다.
"""
from __future__ import annotations

import os

import firebase_admin
from firebase_admin import auth, credentials, firestore
from google.auth.credentials import AnonymousCredentials

from backend.publish import NOTICES, REVIEW_QUEUE, SAVED, USERS

_PROFILE_FIELDS = ("university_id", "major_id", "grade", "enrollment_status", "interest_ids", "target_role_ids", "updated_at")


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


class FirestoreSink(_Base):
    """NoticeSink: 공개 공고와 검토 대기."""

    def get_public(self, notice_id):
        snap = self.db.collection(NOTICES).document(notice_id).get()
        return snap.to_dict() if snap.exists else None

    def put_public(self, notice):
        self.db.collection(NOTICES).document(notice["notice_id"]).set(notice)

    def delete_public(self, notice_id):
        self.db.collection(NOTICES).document(notice_id).delete()

    def put_review(self, notice, issues):
        self.db.collection(REVIEW_QUEUE).document(notice["notice_id"]).set({"notice": notice, "issues": issues})

    def delete_review(self, notice_id):
        self.db.collection(REVIEW_QUEUE).document(notice_id).delete()
