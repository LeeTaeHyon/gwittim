"""Cloud Run 실행용 앱: Firebase Admin 저장소·토큰 검증을 쓴다. 배포는 팀장의 별도 요청 후.

GWITTIM_FIREBASE_PROJECT_ID=<프로젝트 ID> uv run uvicorn backend.api.server:app --port 8080
에뮬레이터: FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 와 demo-* 프로젝트 ID
"""
import os

from backend.agent.llm import check_startup
from backend.firebase_store import (
    FirebaseTokenVerifier,
    FirestoreCredits,
    FirestoreKakaoInbox,
    FirestoreNotices,
    FirestoreProfiles,
    FirestoreReports,
    FirestoreSaved,
    FirestoreSpend,
    init_app,
)

from .app import create_app
from .deps import CachedNoticeReader, Deps

check_startup()  # 고른 LLM 제공자를 이 환경에서 쓸 수 없으면(Cloud Run의 cli 등) 시작을 막는다

_firebase = init_app(os.environ["GWITTIM_FIREBASE_PROJECT_ID"])

app = create_app(
    Deps(
        verifier=FirebaseTokenVerifier(_firebase),
        notices=CachedNoticeReader(FirestoreNotices(_firebase)),  # Firestore 읽기 비용 (docs/cost-estimate.md)
        profiles=FirestoreProfiles(_firebase),
        saved=FirestoreSaved(_firebase),
        credits=FirestoreCredits(_firebase),
        reports=FirestoreReports(_firebase),
        spend=FirestoreSpend(_firebase),
        # 수집 토큰이 없으면 /v1/ingest/kakao는 404 (D-036). 토큰은 Cloud Run 환경변수로만 둔다
        kakao_inbox=FirestoreKakaoInbox(_firebase),
        ingest_token=os.environ.get("GWITTIM_INGEST_TOKEN") or None,
    )
)
