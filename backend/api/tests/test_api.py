import copy
import json
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend.api import Deps, FakeTokenVerifier, InMemoryNotices, InMemoryProfiles, InMemorySaved, create_app
from backend.contracts import schema_errors

ROOT = Path(__file__).resolve().parents[3]
ALICE = {"Authorization": "Bearer token-alice"}
BOB = {"Authorization": "Bearer token-bob"}


def fixture(name):
    return json.loads((ROOT / "fixtures/valid" / name).read_text(encoding="utf-8"))


class FixedClock:
    def now(self):
        return datetime(2026, 10, 17, 3, 5, tzinfo=timezone.utc)  # KST 10/17 12:05


@pytest.fixture
def deps():
    notices = {
        n["notice_id"]: n
        for n in (fixture(f"notice/{p.stem}.json") for p in sorted((ROOT / "fixtures/valid/notice").glob("*.json")))
    }
    return Deps(
        verifier=FakeTokenVerifier({"token-alice": "alice", "token-bob": "bob"}),
        notices=InMemoryNotices(notices),
        profiles=InMemoryProfiles(),
        saved=InMemorySaved(),
        clock=FixedClock(),
    )


@pytest.fixture
def client(deps):
    return TestClient(create_app(deps), raise_server_exceptions=False)


def profile_body():
    body = fixture("user_profile/complete.json")
    del body["updated_at"]
    return body


def assert_error(resp, status, code):
    assert resp.status_code == status
    assert schema_errors("api_error", resp.json()) == []
    assert resp.json()["error"]["code"] == code


# ---------- 인증 ----------

@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}, {"Authorization": "token-alice"}])
def test_requires_valid_token(client, headers):
    assert_error(client.get("/v1/recommendations", headers=headers), 401, "unauthenticated")


# ---------- 프로필 ----------

def test_profile_roundtrip_sets_updated_at(client):
    assert_error(client.get("/v1/profile", headers=ALICE), 404, "not_found")
    resp = client.put("/v1/profile", headers=ALICE, json=profile_body())
    assert resp.status_code == 200
    assert resp.json()["updated_at"] == "2026-10-17T03:05:00Z"
    assert client.get("/v1/profile", headers=ALICE).json() == resp.json()


def test_profile_rejects_user_id_and_unknown_codes(client):
    assert_error(client.put("/v1/profile", headers=ALICE, json={**profile_body(), "user_id": "bob"}), 400, "invalid_argument")
    assert_error(client.put("/v1/profile", headers=ALICE, json={**profile_body(), "major_id": "mjc.nope"}), 400, "invalid_argument")
    assert_error(client.put("/v1/profile", headers=ALICE, json={**profile_body(), "grade": 9}), 400, "invalid_argument")


def test_profile_unlisted_school_requires_null_major(client):
    """'목록에 없는 학교'(unlisted)는 저장되고, 학과가 있으면 invalid_argument (D-043)."""
    unlisted = {**profile_body(), "university_id": "unlisted", "major_id": None}
    resp = client.put("/v1/profile", headers=ALICE, json=unlisted)
    assert resp.status_code == 200
    assert resp.json()["university_id"] == "unlisted" and resp.json()["major_id"] is None
    assert_error(client.put("/v1/profile", headers=ALICE, json={**unlisted, "major_id": "mjc.computer_engineering"}), 400, "invalid_argument")
    assert client.get("/v1/profile", headers=ALICE).json()["major_id"] is None  # 거절된 요청은 저장되지 않음


def test_unlisted_student_recommendations_exclude_school_notices(client):
    client.put("/v1/profile", headers=ALICE, json={**profile_body(), "university_id": "unlisted", "major_id": None})
    ids = [i["notice"]["notice_id"] for i in client.get("/v1/recommendations", headers=ALICE).json()["items"]]
    assert "n_synthetic_0101" in ids  # 교외(wevity_contest)
    assert not any(i.startswith("n_synthetic_000") or i.startswith("n_synthetic_kakao") for i in ids)  # 학교 출처


def test_profile_limits_interests_and_roles_to_five(client):
    """관심사·직무는 각각 최대 5개 (D-031)."""
    five = ["ai_data", "software", "security", "design", "media_content"]
    assert client.put("/v1/profile", headers=ALICE, json={**profile_body(), "interest_ids": five}).status_code == 200
    six = [*five, "startup"]
    assert_error(client.put("/v1/profile", headers=ALICE, json={**profile_body(), "interest_ids": six}), 400, "invalid_argument")
    roles = ["software_developer", "data_ai", "designer", "marketer", "service", "accountant"]
    assert_error(client.put("/v1/profile", headers=ALICE, json={**profile_body(), "target_role_ids": roles}), 400, "invalid_argument")


def test_users_cannot_see_each_other(client):
    client.put("/v1/profile", headers=ALICE, json=profile_body())
    client.put("/v1/saved/n_synthetic_0004", headers=ALICE)
    assert_error(client.get("/v1/profile", headers=BOB), 404, "not_found")
    assert client.get("/v1/saved", headers=BOB).json()["items"] == []


# ---------- 추천·공고 ----------

def test_recommendations_personalized_after_profile(client):
    latest = client.get("/v1/recommendations", headers=ALICE).json()
    assert latest["mode"] == "latest"
    client.put("/v1/profile", headers=ALICE, json=profile_body())
    out = client.get("/v1/recommendations", headers=ALICE).json()
    assert schema_errors("recommendation_list_response", out) == []
    assert out["mode"] == "personalized"
    assert out["items"][0]["notice"]["notice_id"] == "n_synthetic_0004"
    assert "n_synthetic_0005" not in [i["notice"]["notice_id"] for i in out["items"]]  # review_pending


def test_recommendations_search_and_category(client):
    """공고 탭 검색·분류 칩 (D-026): 추천 후보 전체에서 거르고, 제외 규칙은 그대로다."""
    ids = lambda r: [i["notice"]["notice_id"] for i in r.json()["items"]]
    assert client.put("/v1/profile", headers=ALICE, json=profile_body()).status_code == 200  # 학교 공지는 같은 학교 학생에게만 (rank-0.8)
    assert ids(client.get("/v1/recommendations?q=해외연수", headers=ALICE)) == ["n_synthetic_0002"]  # 띄어쓰기 무시
    contest = client.get("/v1/recommendations?category=contest", headers=ALICE)
    assert schema_errors("recommendation_list_response", contest.json()) == []
    assert sorted(ids(contest)) == ["n_synthetic_0001", "n_synthetic_0003", "n_synthetic_0101"]  # 0005는 검토 대기라 빠짐, 0101은 교외 공모전 샘플
    assert ids(client.get("/v1/recommendations?category=contest&q=글쓰기", headers=ALICE)) == ["n_synthetic_0003"]
    assert ids(client.get("/v1/recommendations?q=없는말", headers=ALICE)) == []
    assert_error(client.get("/v1/recommendations?category=nope", headers=ALICE), 400, "invalid_argument")
    assert_error(client.get("/v1/recommendations?q=" + "가" * 51, headers=ALICE), 400, "invalid_argument")


def test_recommendations_limit_validated(client):
    assert_error(client.get("/v1/recommendations?limit=500", headers=ALICE), 400, "invalid_argument")
    assert len(client.get("/v1/recommendations?limit=1", headers=ALICE).json()["items"]) == 1


def test_get_notice_hides_review_pending(client):
    assert client.get("/v1/notices/n_synthetic_0001", headers=ALICE).status_code == 200
    assert_error(client.get("/v1/notices/n_synthetic_0005", headers=ALICE), 404, "not_found")
    assert_error(client.get("/v1/notices/missing", headers=ALICE), 404, "not_found")


# ---------- 저장 ----------

def test_save_is_idempotent_and_snapshots_deadline(client):
    first = client.put("/v1/saved/n_synthetic_0004", headers=ALICE).json()
    again = client.put("/v1/saved/n_synthetic_0004", headers=ALICE).json()
    assert first == again
    assert schema_errors("saved_notice", first) == []
    assert first["saved_deadline_snapshot"]["date"] == "2026-10-30"
    assert_error(client.put("/v1/saved/missing", headers=ALICE), 404, "not_found")


def test_saved_list_links_latest_notice(client, deps):
    client.put("/v1/saved/n_synthetic_0004", headers=ALICE)
    changed = copy.deepcopy(deps.notices.notices["n_synthetic_0004"])
    changed["notice_version"] = 3
    changed["application_deadline"]["date"] = "2026-11-06"
    deps.notices.notices["n_synthetic_0004"] = changed

    out = client.get("/v1/saved", headers=ALICE).json()
    assert schema_errors("saved_notice_list_response", out) == []
    item = out["items"][0]
    assert item["saved"]["saved_deadline_snapshot"]["date"] == "2026-10-30"  # 저장 당시
    assert item["notice"]["application_deadline"]["date"] == "2026-11-06"  # 최신
    assert item["notice"]["notice_version"] == 3


def test_delete_saved_is_idempotent(client):
    client.put("/v1/saved/n_synthetic_0004", headers=ALICE)
    assert client.delete("/v1/saved/n_synthetic_0004", headers=ALICE).status_code == 204
    assert client.delete("/v1/saved/n_synthetic_0004", headers=ALICE).status_code == 204
    assert client.get("/v1/saved", headers=ALICE).json()["items"] == []


def test_account_deletion_removes_profile_and_saved(client, deps):
    client.put("/v1/profile", headers=ALICE, json=profile_body())
    client.put("/v1/saved/n_synthetic_0004", headers=ALICE)
    assert client.delete("/v1/profile", headers=ALICE).status_code == 204
    assert deps.profiles.get("alice") is None and deps.saved.list("alice") == []
    assert deps.notices.get("n_synthetic_0004") is not None  # 공개 공고는 유지


# ---------- 오류 ----------

def test_unexpected_error_hides_details(deps):
    class Broken(InMemoryNotices):
        def list_published(self):
            raise RuntimeError("db password=secret at line 42")

    deps.notices = Broken(deps.notices.notices)
    resp = TestClient(create_app(deps), raise_server_exceptions=False).get("/v1/recommendations", headers=ALICE)
    assert_error(resp, 503, "unavailable")
    assert "secret" not in resp.text and "RuntimeError" not in resp.text


# ---------- 공고 목록 캐시 (비용) ----------

def test_cached_notice_reader_limits_reads(deps):
    from backend.api import CachedNoticeReader

    calls = []

    class Counting(InMemoryNotices):
        def list_published(self):
            calls.append(1)
            return super().list_published()

    now = [0.0]
    reader = CachedNoticeReader(Counting(deps.notices.notices), ttl_seconds=300, clock=lambda: now[0])
    for _ in range(10):
        reader.list_published()
    assert len(calls) == 1
    now[0] = 299
    reader.list_published()
    assert len(calls) == 1
    now[0] = 300
    reader.list_published()
    assert len(calls) == 2
    assert reader.get("n_synthetic_0005") is None  # 단건은 캐시 없이 published 규칙 그대로


# ---------- 팀장 폰 수집기 올리기 (D-036) ----------

INGEST = {"X-Ingest-Token": "ingest-secret"}
PHONE_NOTICE = {
    "room": "명지전문대학 합성채널",
    "sent_at": "2026-10-20T14:05:00+09:00",
    "text": "[합성 샘플] 2026 교내 AI 데이터 분석 경진대회 참가팀 모집\n대상: 재학생\n문의: 010-1234-5678",
    "model_version": "kakao-0.2",
    "classification": {"category": "contest", "interest_ids": ["ai_data"], "unsure": False},
}


@pytest.fixture
def ingest_client(deps):
    from backend.collectors.mjc_kakao.inbox import InMemoryInbox

    deps.kakao_inbox, deps.ingest_token = InMemoryInbox(), "ingest-secret"
    return TestClient(create_app(deps), raise_server_exceptions=False), deps.kakao_inbox


def test_ingest_is_hidden_without_token_config(client):
    assert_error(client.post("/v1/ingest/kakao", json=PHONE_NOTICE, headers=INGEST), 404, "not_found")


@pytest.mark.parametrize("headers,status,code", [
    ({}, 401, "unauthenticated"),
    ({"X-Ingest-Token": "wrong"}, 403, "permission_denied"),
    (ALICE, 401, "unauthenticated"),  # 사용자 로그인 토큰으로는 올릴 수 없다
])
def test_ingest_needs_ingest_token(ingest_client, headers, status, code):
    client, inbox = ingest_client
    assert_error(client.post("/v1/ingest/kakao", json=PHONE_NOTICE, headers=headers), status, code)
    assert inbox.docs == {}


def test_ingest_stores_masked_broadcast_once(ingest_client):
    client, inbox = ingest_client
    first = client.post("/v1/ingest/kakao", json=PHONE_NOTICE, headers=INGEST)
    assert first.status_code == 200 and first.json()["stored"] and first.json()["new"]
    again = client.post("/v1/ingest/kakao", json=PHONE_NOTICE, headers=INGEST)
    assert again.json() == {**first.json(), "new": False}  # 같은 알림을 다시 올려도 한 건
    (doc,) = inbox.docs.values()
    assert "010-1234-5678" not in doc["text"] and "<휴대폰>" in doc["text"]  # 서버에서도 다시 가린다
    assert doc["received_at"] == "2026-10-17T03:05:00Z"
    assert doc["phone"]["classification"]["category"] == "contest"


def test_ingest_drops_personal_notice(ingest_client):
    client, inbox = ingest_client
    personal = {**PHONE_NOTICE, "text": "[합성 샘플] 데이터베이스 801반 강의를 아직 수강하지 않았습니다. 2026123456 학생"}
    resp = client.post("/v1/ingest/kakao", json=personal, headers=INGEST)
    assert resp.status_code == 200 and resp.json() == {"stored": False, "reason": "not_broadcast"}
    assert inbox.docs == {}


@pytest.mark.parametrize("change", [
    {"room": "다른 방"},
    {"sent_at": "2026-10-20 14:05"},
    {"sent_at": "2026-10-20T14:05:30+09:00"},
    {"text": ""},
    {"text": "가" * 8001},
])
def test_ingest_rejects_bad_fields(ingest_client, change):
    client, inbox = ingest_client
    assert_error(client.post("/v1/ingest/kakao", json={**PHONE_NOTICE, **change}, headers=INGEST), 400, "invalid_argument")
    assert inbox.docs == {}


def test_poster_only_in_detail(client):
    notice = fixture("notice/date_only_timezone_unknown.json")
    nid = notice["notice_id"]
    assert client.get(f"/v1/notices/{nid}", headers=ALICE).json()["poster_url"] == notice["poster_url"]
    client.put("/v1/profile", headers=ALICE, json=profile_body())
    client.put(f"/v1/saved/{nid}", headers=ALICE)
    for path in ("/v1/recommendations", "/v1/recommendations?q=" + notice["title"], "/v1/saved"):
        items = client.get(path, headers=ALICE).json()["items"]
        assert nid in [item["notice"]["notice_id"] for item in items]
        assert all("poster_url" not in item["notice"] for item in items)
