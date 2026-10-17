"""Firebase Emulator 통합 테스트. 에뮬레이터가 없으면 건너뛴다.

firebase emulators:exec --only firestore,auth --project demo-gwittim "uv run pytest backend/tests/test_firebase_emulator.py"
"""
import json
import os
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    not (os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="Firestore·Auth 에뮬레이터 필요",
)

ROOT = Path(__file__).resolve().parents[2]
PROJECT = "demo-gwittim"


def fixture(name):
    return json.loads((ROOT / "fixtures/valid" / name).read_text(encoding="utf-8"))


def sign_up() -> tuple[str, str]:
    """Auth 에뮬레이터에 합성 사용자를 만들고 ID 토큰을 받는다."""
    host = os.environ["FIREBASE_AUTH_EMULATOR_HOST"]
    body = json.dumps({"email": f"{uuid.uuid4().hex}@example.invalid", "password": "synthetic-pw", "returnSecureToken": True})
    req = urllib.request.Request(
        f"http://{host}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-key",
        data=body.encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    return data["localId"], data["idToken"]


@pytest.fixture(scope="module")
def app():
    from backend.firebase_store import init_app

    return init_app(PROJECT, name="emulator-test")


@pytest.fixture
def client(app):
    from fastapi.testclient import TestClient

    from backend.api import Deps, create_app
    from backend.firebase_store import FirebaseTokenVerifier, FirestoreNotices, FirestoreProfiles, FirestoreSaved, FirestoreSink
    from backend.publish import publish

    sink = FirestoreSink(app)
    for p in sorted((ROOT / "fixtures/valid/notice").glob("*.json")):
        notice = json.loads(p.read_text(encoding="utf-8"))
        publish(notice, [], sink)

    class Clock:
        def now(self):
            return datetime(2026, 10, 17, 3, 5, tzinfo=timezone.utc)

    deps = Deps(
        verifier=FirebaseTokenVerifier(app),
        notices=FirestoreNotices(app),
        profiles=FirestoreProfiles(app),
        saved=FirestoreSaved(app),
        clock=Clock(),
    )
    return TestClient(create_app(deps), raise_server_exceptions=False), sink


def test_publish_keeps_review_pending_out_of_public(client):
    _, sink = client
    assert sink.get_public("n_synthetic_0001")["notice_id"] == "n_synthetic_0001"
    assert sink.get_public("n_synthetic_0005") is None  # review_pending → 검토 대기
    snap = sink.db.collection("review_queue").document("n_synthetic_0005").get()
    assert snap.exists


def test_full_api_flow_with_real_tokens(client):
    from backend.contracts import schema_errors

    api, _ = client
    uid, token = sign_up()
    other_uid, other_token = sign_up()
    h = {"Authorization": f"Bearer {token}"}

    assert api.get("/v1/recommendations", headers={"Authorization": "Bearer not-a-token"}).status_code == 401

    profile = fixture("user_profile/complete.json")
    del profile["updated_at"]
    assert api.put("/v1/profile", headers=h, json=profile).status_code == 200

    rec = api.get("/v1/recommendations", headers=h).json()
    assert schema_errors("recommendation_list_response", rec) == []
    assert rec["mode"] == "personalized"
    assert rec["items"][0]["notice"]["notice_id"] == "n_synthetic_0004"

    assert api.put("/v1/saved/n_synthetic_0004", headers=h).status_code == 200
    saved = api.get("/v1/saved", headers=h).json()
    assert schema_errors("saved_notice_list_response", saved) == []
    assert [i["notice"]["notice_id"] for i in saved["items"]] == ["n_synthetic_0004"]

    other = {"Authorization": f"Bearer {other_token}"}
    assert api.get("/v1/profile", headers=other).status_code == 404
    assert api.get("/v1/saved", headers=other).json()["items"] == []

    assert api.delete("/v1/profile", headers=h).status_code == 204
    assert api.get("/v1/profile", headers=h).status_code == 404
    assert api.get("/v1/saved", headers=h).json()["items"] == []
