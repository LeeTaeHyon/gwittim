"""M1 경로 전체를 에뮬레이터에서 확인한다: 실제 학교 공지 수집 → 분석 → Firestore 게시 → API(실제 ID 토큰).

실제 사이트에 요청하므로 기본은 건너뛴다. 실행:
GWITTIM_E2E_LIVE=1 firebase emulators:exec --only firestore,auth --project demo-gwittim \\
  "uv run pytest backend/tests/test_e2e_emulator.py"
"""
import json
import os
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

import pytest

pytestmark = pytest.mark.skipif(
    not (os.environ.get("GWITTIM_E2E_LIVE") and os.environ.get("FIRESTORE_EMULATOR_HOST") and os.environ.get("FIREBASE_AUTH_EMULATOR_HOST")),
    reason="GWITTIM_E2E_LIVE=1 과 Firestore·Auth 에뮬레이터 필요",
)

KST = timezone(timedelta(hours=9))


def id_token() -> str:
    host = os.environ["FIREBASE_AUTH_EMULATOR_HOST"]
    body = json.dumps({"email": f"{uuid.uuid4().hex}@example.invalid", "password": "synthetic-pw", "returnSecureToken": True})
    req = urllib.request.Request(
        f"http://{host}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-key",
        data=body.encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["idToken"]


def test_real_notices_flow_to_api(tmp_path):
    from fastapi.testclient import TestClient

    from backend.api import Deps, create_app
    from backend.batch import run_batch
    from backend.collectors.common import JsonFileStore
    from backend.collectors.mjc_www import BOARDS
    from backend.contracts import schema_errors
    from backend.firebase_store import FirebaseTokenVerifier, FirestoreNotices, FirestoreProfiles, FirestoreSaved, FirestoreSink, init_app

    app = init_app("demo-gwittim", name="e2e")
    notices: dict = {}
    report = run_batch(
        [BOARDS["mjc_www_notice"]],
        store=JsonFileStore(tmp_path / "pipeline"),
        sink=FirestoreSink(app),
        notices=notices,
        today=datetime.now(KST).date(),
        pages=1,
        max_items=5,
    )
    print("batch:", report)
    assert report.collected == 5 and report.fetch_errors == []
    assert report.published + report.queued == 5

    api = TestClient(create_app(Deps(
        verifier=FirebaseTokenVerifier(app),
        notices=FirestoreNotices(app),
        profiles=FirestoreProfiles(app),
        saved=FirestoreSaved(app),
    )))
    h = {"Authorization": f"Bearer {id_token()}"}
    rec = api.get("/v1/recommendations", headers=h).json()
    assert schema_errors("recommendation_list_response", rec) == []
    published = [n for n in notices.values() if n["publication_status"] == "published" and n["lifecycle_status"] not in ("closed", "removed")]
    assert {i["notice"]["notice_id"] for i in rec["items"]} == {n["notice_id"] for n in published}
    for item in rec["items"]:
        assert item["notice"]["source_url"].startswith("https://www.mjc.ac.kr/bbs/data/view.do")
        detail = api.get(f"/v1/notices/{item['notice']['notice_id']}", headers=h)
        assert detail.status_code == 200 and schema_errors("notice", detail.json()) == []
