"""Cloud Run 실행용 앱: Firebase Admin 저장소·토큰 검증을 쓴다. 배포는 팀장의 별도 요청 후.

GWITTIM_FIREBASE_PROJECT_ID=<프로젝트 ID> uv run uvicorn backend.api.server:app --port 8080
에뮬레이터: FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 와 demo-* 프로젝트 ID
"""
import os

from backend.firebase_store import FirebaseTokenVerifier, FirestoreNotices, FirestoreProfiles, FirestoreSaved, init_app

from .app import create_app
from .deps import CachedNoticeReader, Deps

_firebase = init_app(os.environ["GWITTIM_FIREBASE_PROJECT_ID"])

app = create_app(
    Deps(
        verifier=FirebaseTokenVerifier(_firebase),
        notices=CachedNoticeReader(FirestoreNotices(_firebase)),  # Firestore 읽기 비용 (docs/cost-estimate.md)
        profiles=FirestoreProfiles(_firebase),
        saved=FirestoreSaved(_firebase),
    )
)
