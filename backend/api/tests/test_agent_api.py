"""AI 상세 분석·크레딧 API (P7a). 제공자는 fake/가짜만 쓰고 실제 LLM은 부르지 않는다."""
import json
import threading
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend.agent import llm
from backend.agent.credits import DETAIL_ANALYSIS, reserve, signup
from backend.agent.prompt import build_messages
from backend.agent.service import purge_expired_reports
from backend.api import Deps, FakeTokenVerifier, InMemoryNotices, InMemoryProfiles, InMemorySaved, create_app
from backend.api.deps import InMemoryCredits, InMemoryReports
from backend.contracts import schema_errors

ROOT = Path(__file__).resolve().parents[3]
ALICE = {"Authorization": "Bearer token-alice"}
BOB = {"Authorization": "Bearer token-bob"}
GUEST = {"Authorization": "Bearer token-guest"}  # 익명 계정 (D-054)
NOTICE = "n_synthetic_0001"  # 마감 2026-11-02(날짜만) -> 저장본 만료 2026-12-02 0시 KST
CONSENT = {"version": "2026-11-21", "agreed_at": "2020-01-01T00:00:00Z"}


def fixture(name):
    return json.loads((ROOT / "fixtures/valid" / name).read_text(encoding="utf-8"))


class Clock:
    def __init__(self):
        self.moment = datetime(2026, 10, 17, 3, 5, tzinfo=timezone.utc)  # KST 10/17 12:05

    def now(self):
        return self.moment


class CountingProvider:
    name = "counting"

    def __init__(self):
        self.calls = 0
        self.prompts = []

    def generate(self, system, user, notice_id=None):
        self.calls += 1
        self.prompts.append((system, user))
        return llm.FakeProvider().generate(system, user, notice_id)


class FailingProvider:
    name = "failing"

    def generate(self, system, user, notice_id=None):
        raise llm.ProviderCallError("호출 실패")


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def provider():
    return CountingProvider()


@pytest.fixture
def deps(clock, provider):
    notices = {
        n["notice_id"]: n
        for n in (json.loads(p.read_text(encoding="utf-8")) for p in sorted((ROOT / "fixtures/valid/notice").glob("*.json")))
    }
    return Deps(
        verifier=FakeTokenVerifier({"token-alice": "alice", "token-bob": "bob"}, guest_tokens={"token-guest": "guest"}),
        notices=InMemoryNotices(notices),
        profiles=InMemoryProfiles(),
        saved=InMemorySaved(),
        clock=clock,
        llm=provider,
    )


@pytest.fixture
def client(deps):
    return TestClient(create_app(deps), raise_server_exceptions=False)


def profile_body(consent=CONSENT):
    body = fixture("user_profile/complete.json")
    del body["updated_at"]
    if consent:
        body["agent_consent"] = consent
    return body


def consent(client, headers=ALICE):
    assert client.put("/v1/profile", headers=headers, json=profile_body()).status_code == 200


def analyze(client, request_id="r1", chips=None, notice_id=NOTICE, headers=ALICE):
    return client.post(
        "/v1/analysis",
        headers=headers,
        json={"notice_id": notice_id, "request_id": request_id, "chips": {"experience": ["python"]} if chips is None else chips},
    )


def balance(client, headers=ALICE):
    return client.get("/v1/credits", headers=headers).json()["balance"]


def assert_error(resp, status, code):
    assert resp.status_code == status
    assert schema_errors("api_error", resp.json()) == []
    assert resp.json()["error"]["code"] == code


# ---------- 요청 검증 ----------

def test_requires_login(client):
    assert_error(client.post("/v1/analysis", json={}), 401, "unauthenticated")
    assert_error(client.get("/v1/credits"), 401, "unauthenticated")


def test_no_consent_is_consent_required(client, provider):
    assert_error(analyze(client), 403, "consent_required")  # 프로필 없음
    client.put("/v1/profile", headers=ALICE, json=profile_body(consent=None))
    assert_error(analyze(client), 403, "consent_required")  # 프로필은 있으나 동의 없음
    assert provider.calls == 0


def test_unknown_notice_is_not_found(client, provider):
    consent(client)
    assert_error(analyze(client, notice_id="nope"), 404, "not_found")
    assert_error(analyze(client, notice_id="n_synthetic_0005"), 404, "not_found")  # 검토 대기는 비공개
    assert provider.calls == 0
    assert balance(client) == 5


@pytest.mark.parametrize(
    "chips",
    [{"experience": ["none_yet", "python"]}, {"regions": ["any", "seoul"]}, {"period": ["semester"]}, {"extra": []}],
)
def test_bad_chips_are_invalid_argument(client, provider, chips):
    consent(client)
    assert_error(analyze(client, chips=chips), 400, "invalid_argument")
    assert provider.calls == 0


def test_missing_fields_are_invalid_argument(client):
    consent(client)
    assert_error(client.post("/v1/analysis", headers=ALICE, json={"notice_id": NOTICE}), 400, "invalid_argument")


# ---------- 분석 흐름 ----------

def test_first_request_charges_and_stores(client, deps, provider):
    consent(client)
    resp = analyze(client)
    assert resp.status_code == 200
    out = resp.json()
    assert schema_errors("analysis_response", out) == []
    assert out["from_cache"] is False
    assert out["notice_id"] == NOTICE
    assert out["expires_at"] == "2026-12-01T15:00:00Z"  # 마감일 11/02 0시 KST + 30일
    assert provider.calls == 1
    credits = client.get("/v1/credits", headers=ALICE).json()
    assert credits["balance"] == 4
    assert credits["entries"][0] == {"kind": "detail_analysis", "amount": -1, "at": "2026-10-17T03:05:00Z", "ref": NOTICE}
    assert len(deps.reports.docs["alice"]) == 1


def test_no_deadline_notice_expires_after_60_days(client):
    consent(client)
    out = analyze(client, notice_id="n_synthetic_0002").json()
    assert out["expires_at"] == "2026-12-16T03:05:00Z"  # 생성 + 60일


def test_same_chips_new_request_uses_stored_report_and_charges(client, provider):
    consent(client)
    analyze(client, "r1")
    out = analyze(client, "r2").json()
    assert out["from_cache"] is True
    assert schema_errors("analysis_response", out) == []
    assert provider.calls == 1  # LLM은 다시 부르지 않음
    assert balance(client) == 3  # 차감은 한다 (D-039)


def test_different_chips_make_new_report(client, provider):
    consent(client)
    analyze(client, "r1")
    out = analyze(client, "r2", chips={"experience": ["java"]}).json()
    assert out["from_cache"] is False
    assert provider.calls == 2


def test_same_request_id_is_not_charged_twice(client, provider):
    consent(client)
    analyze(client, "r1")
    again = analyze(client, "r1")
    assert again.status_code == 200
    assert again.json()["from_cache"] is True
    assert balance(client) == 4
    assert provider.calls == 1


def test_duplicate_request_id_without_stored_report_is_not_found(client):
    consent(client)
    analyze(client, "r1")
    assert_error(analyze(client, "r1", chips={"experience": ["java"]}), 404, "not_found")
    assert balance(client) == 4


def test_zero_balance_is_insufficient_and_skips_llm(client, provider):
    consent(client)
    experience = ["python", "java", "web_ui", "app_dev", "contest"]
    for i in range(5):
        assert analyze(client, f"r{i}", chips={"experience": experience[: i + 1]}).status_code == 200
    assert balance(client) == 0
    calls = provider.calls
    assert_error(analyze(client, "r9", chips={"period": "vacation"}), 402, "insufficient_credits")
    assert provider.calls == calls


def test_llm_failure_refunds(client, deps):
    consent(client)
    deps.llm = FailingProvider()
    assert_error(analyze(client), 503, "unavailable")
    credits = client.get("/v1/credits", headers=ALICE).json()
    assert credits["balance"] == 5
    assert [e["kind"] for e in credits["entries"]] == ["signup"]
    assert deps.reports.docs == {}
    deps.llm = CountingProvider()  # 같은 요청 id로 다시 시도할 수 있다
    assert analyze(client).status_code == 200
    assert balance(client) == 4


def test_provider_not_ready_refunds(client, deps):
    consent(client)
    deps.llm = llm.get_provider("api", env={})  # 키 없음
    assert_error(analyze(client), 503, "unavailable")
    assert balance(client) == 5


def test_request_in_progress(client, deps, provider):
    consent(client)
    now = deps.clock.now()
    deps.credits.update("alice", lambda s: (reserve(signup(now), DETAIL_ANALYSIS, "r1", now).state, None))
    assert_error(analyze(client, "r1"), 409, "request_in_progress")
    assert provider.calls == 0


# ---------- 프롬프트 ----------

def test_prompt_has_no_identity(client, provider):
    consent(client)
    analyze(client)
    system, user = provider.prompts[0]
    for secret in ("alice", "token-alice", "agreed_at", "updated_at", "request_id", "agent_consent"):
        assert secret not in user
        assert secret not in system
    data = json.loads(user)
    assert data["학생"]["해 본 것"] == ["파이썬"]
    assert data["학생"]["학과"] == "컴퓨터공학과"
    assert data["공고"]["지원 자격 판정"]["결과"] in ("충족", "미충족", "확인 필요")
    assert "합격 가능성" in system and "JSON" in system


def test_build_messages_passes_rule_verdict():
    notice = fixture("notice/explicitly_unrestricted.json")
    verdict = ("not_met", [{"field": "grade", "status": "not_met", "evidence": "3학년", "unknown_reason": None}])
    system, user = build_messages(notice, {"grade": 2}, verdict, date(2026, 11, 21))
    assert '"오늘": "2026-11-21"' in user
    assert json.loads(user)["공고"]["지원 자격 판정"]["결과"] == "미충족"
    assert "해요체(~해요)와 평서형(~이다, ~한다)은 쓰지 않습니다" in system


# ---------- 다시 보기·크레딧 ----------

def test_get_analysis_returns_stored_without_charge(client, provider):
    consent(client)
    assert_error(client.get(f"/v1/analysis/{NOTICE}", headers=ALICE), 404, "not_found")
    analyze(client)
    resp = client.get(f"/v1/analysis/{NOTICE}", headers=ALICE)
    assert resp.status_code == 200
    assert resp.json()["from_cache"] is True
    assert schema_errors("analysis_response", resp.json()) == []
    assert balance(client) == 4
    assert provider.calls == 1
    assert_error(client.get(f"/v1/analysis/{NOTICE}", headers=BOB), 404, "not_found")  # 남의 것은 안 보임


def test_get_analysis_after_expiry_is_not_found(client, clock):
    consent(client)
    analyze(client)
    clock.moment = datetime(2026, 12, 1, 15, 0, tzinfo=timezone.utc)  # 정확히 만료 시각
    assert_error(client.get(f"/v1/analysis/{NOTICE}", headers=ALICE), 404, "not_found")


def test_get_analysis_picks_latest(client, deps, clock):
    consent(client)
    analyze(client, "r1", chips={"experience": ["python"]})
    clock.moment += timedelta(minutes=1)
    analyze(client, "r2", chips={"experience": ["java"]})
    latest = deps.reports.latest_for_notice("alice", NOTICE, clock.now())
    assert latest["request_id"] == "r2"
    assert client.get(f"/v1/analysis/{NOTICE}", headers=ALICE).status_code == 200


def test_credits_first_read_is_signup_gift(client):
    out = client.get("/v1/credits", headers=ALICE).json()
    assert schema_errors("credits", out) == []
    assert out["balance"] == 5
    assert out["next_refill_at"] is None  # 가득 참
    assert out["entries"] == [{"kind": "signup", "amount": 5, "at": "2026-10-17T03:05:00Z", "ref": None}]


def test_credits_entries_newest_first_and_refill(client, clock):
    consent(client)
    analyze(client)
    clock.moment += timedelta(days=1)
    out = client.get("/v1/credits", headers=ALICE).json()
    assert schema_errors("credits", out) == []
    assert out["balance"] == 5
    assert [e["kind"] for e in out["entries"]] == ["daily", "detail_analysis", "signup"]
    clock.moment += timedelta(hours=1)
    analyze(client, "r2", chips={"experience": ["java"]})
    out = client.get("/v1/credits", headers=ALICE).json()
    assert schema_errors("credits", out) == []
    assert out["balance"] == 4
    assert out["next_refill_at"] == "2026-10-18T15:00:00Z"  # 다음 날 0시 KST
    ats = [e["at"] for e in out["entries"]]
    assert ats == sorted(ats, reverse=True)


# ---------- 동의 철회·시각·탈퇴 ----------

def test_agreed_at_is_server_time_and_kept_when_unchanged(client, clock):
    resp = client.put("/v1/profile", headers=ALICE, json=profile_body())
    assert resp.json()["agent_consent"] == {"version": "2026-11-21", "agreed_at": "2026-10-17T03:05:00Z"}  # 앱 값 무시
    clock.moment += timedelta(days=3)
    again = client.put("/v1/profile", headers=ALICE, json=profile_body()).json()
    assert again["agent_consent"]["agreed_at"] == "2026-10-17T03:05:00Z"
    bumped = client.put("/v1/profile", headers=ALICE, json=profile_body({"version": "2026-12-01", "agreed_at": "2020-01-01T00:00:00Z"})).json()
    assert bumped["agent_consent"] == {"version": "2026-12-01", "agreed_at": "2026-10-20T03:05:00Z"}


def test_withdrawal_deletes_reports(client, deps):
    consent(client)
    consent(client, BOB)
    analyze(client)
    analyze(client, headers=BOB)
    client.put("/v1/profile", headers=ALICE, json=profile_body(consent=None))
    assert "alice" not in deps.reports.docs
    assert "bob" in deps.reports.docs
    assert_error(client.get(f"/v1/analysis/{NOTICE}", headers=ALICE), 404, "not_found")
    assert_error(analyze(client, "r2"), 403, "consent_required")


def test_profile_edit_without_consent_change_keeps_reports(client, deps):
    consent(client)
    analyze(client)
    client.put("/v1/profile", headers=ALICE, json={**profile_body(), "grade": 3})
    assert len(deps.reports.docs["alice"]) == 1


def test_account_deletion_removes_credits_and_reports(client, deps):
    consent(client)
    analyze(client)
    assert client.delete("/v1/profile", headers=ALICE).status_code == 204
    assert "alice" not in deps.reports.docs
    assert "alice" not in deps.credits.states
    assert client.delete("/v1/profile", headers=ALICE).status_code == 204  # 반복 요청 안전


# ---------- 만료 삭제·저장소 ----------

def test_delete_expired(clock):
    reports = InMemoryReports()
    now = clock.now()
    for uid, key, days in (("a", "k1", -1), ("a", "k2", 1), ("b", "k3", 0)):
        doc = {"notice_id": "n", "key": key, "report": {}, "created_at": now, "expires_at": now + timedelta(days=days), "request_id": "r"}
        reports.put(uid, doc)
    assert purge_expired_reports(reports, now) == 2  # 정확히 만료 시각인 것도 지운다
    assert list(reports.docs["a"]) == ["k2"]
    assert purge_expired_reports(reports, now) == 0


def test_credit_update_is_serialized():
    store = InMemoryCredits()
    now = datetime(2026, 10, 17, tzinfo=timezone.utc)
    results = []

    def go(i):
        def fn(state):
            r = reserve(state or signup(now), DETAIL_ANALYSIS, f"r{i}", now)
            return r.state, r.status

        results.append(store.update("u", fn))

    threads = [threading.Thread(target=go, args=(i,)) for i in range(12)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert results.count("held") == 5 and results.count("insufficient") == 7


def test_firestore_credit_state_roundtrip():
    from backend.firebase_store import _credit_state_from_dict, _credit_state_to_dict

    state = signup(datetime(2026, 10, 17, 3, 5, tzinfo=timezone.utc))
    held = reserve(state, DETAIL_ANALYSIS, "r1", state.entries[0].at).state
    data = _credit_state_to_dict(held)
    json.dumps(data)  # Firestore에 넣는 값은 문자열·숫자·목록뿐
    assert _credit_state_from_dict(data) == held


# ---------- 비용 상한(D-039)·Cloud Run fake ----------

class CostProvider:
    """호출마다 비용(원)이 정해진 가짜 제공자."""

    name = "cost"

    def __init__(self, krw=100.0, fail=False):
        self.calls = 0
        self.krw = krw
        self.fail = fail

    def generate(self, system, user, notice_id=None):
        self.calls += 1
        tokens = int(self.krw / 1400 * 1_000_000 / 0.5)  # 출력 토큰만으로 원하는 비용을 만든다
        usage = llm.Usage("cost", 0.0, 0, tokens)
        if self.fail:
            exc = llm.ReportFormatError("잘림")
            exc.usage = usage
            raise exc
        return llm.LLMResult(dict(llm.FAKE_REPORT), usage)


def test_fake_on_cloud_run_answers_unavailable_and_keeps_credits(client, deps):
    consent(client)
    deps.llm = llm.get_provider("fake", env={"K_SERVICE": "gwittim-api"})
    assert_error(analyze(client), 503, "unavailable")
    assert balance(client) == 5
    assert deps.reports.docs == {}


def test_monthly_cap_blocks_new_analysis(client, deps, monkeypatch):
    monkeypatch.setenv("GWITTIM_LLM_MONTHLY_CAP_KRW", "1000")
    consent(client)
    deps.llm = provider = CostProvider()
    deps.spend.add(deps.month_kst(), 1000)
    assert_error(analyze(client), 503, "unavailable")
    assert provider.calls == 0 and balance(client) == 5


def test_default_cap_is_30000(client, deps, monkeypatch):
    monkeypatch.delenv("GWITTIM_LLM_MONTHLY_CAP_KRW", raising=False)
    consent(client)
    deps.llm = provider = CostProvider()
    deps.spend.add(deps.month_kst(), 29999)
    assert analyze(client, "r1").status_code == 200
    assert_error(analyze(client, "r2", chips={"period": "vacation"}), 503, "unavailable")
    assert provider.calls == 1


def test_stored_report_reuse_allowed_over_cap(client, deps, monkeypatch):
    monkeypatch.setenv("GWITTIM_LLM_MONTHLY_CAP_KRW", "1000")
    consent(client)
    deps.llm = provider = CostProvider()
    assert analyze(client, "r1").status_code == 200
    deps.spend.add(deps.month_kst(), 5000)
    resp = analyze(client, "r2")
    assert resp.status_code == 200 and resp.json()["from_cache"] is True
    assert provider.calls == 1 and balance(client) == 3
    assert client.get(f"/v1/analysis/{NOTICE}", headers=ALICE).status_code == 200  # 받은 리포트는 계속 보임


def test_cost_is_accumulated_after_call(client, deps):
    consent(client)
    deps.llm = CostProvider(krw=100.0)
    analyze(client, "r1")
    assert deps.spend.get(deps.month_kst()) == pytest.approx(100.0, rel=0.01)
    analyze(client, "r2", chips={"period": "vacation"})
    assert deps.spend.get(deps.month_kst()) == pytest.approx(200.0, rel=0.01)


def test_failed_call_with_usage_is_accumulated_and_refunded(client, deps):
    consent(client)
    deps.llm = CostProvider(krw=100.0, fail=True)
    assert_error(analyze(client), 503, "unavailable")
    assert deps.spend.get(deps.month_kst()) == pytest.approx(100.0, rel=0.01)
    assert balance(client) == 5


def test_failed_call_without_usage_adds_nothing(client, deps):
    consent(client)
    deps.llm = FailingProvider()
    analyze(client)
    assert deps.spend.get(deps.month_kst()) == 0


def test_unknown_cost_counts_zero(client, deps):
    consent(client)
    assert analyze(client).status_code == 200  # fake: 토큰 수 모름
    assert deps.spend.get(deps.month_kst()) == 0


def test_new_month_kst_allows_again(client, deps, clock, monkeypatch):
    monkeypatch.setenv("GWITTIM_LLM_MONTHLY_CAP_KRW", "1000")
    consent(client)
    deps.llm = provider = CostProvider()
    clock.moment = datetime(2026, 10, 31, 14, 59, tzinfo=timezone.utc)  # KST 10/31 23:59
    deps.spend.add("2026-10", 1000)
    assert_error(analyze(client, "r1"), 503, "unavailable")
    clock.moment = datetime(2026, 10, 31, 15, 0, tzinfo=timezone.utc)  # KST 11/01 00:00
    assert deps.month_kst() == "2026-11"
    assert analyze(client, "r2").status_code == 200
    assert provider.calls == 1


def test_in_memory_spend_is_serialized():
    from backend.api.deps import InMemorySpend

    store = InMemorySpend()
    threads = [threading.Thread(target=lambda: [store.add("2026-11", 1.5) for _ in range(100)]) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert store.get("2026-11") == 1200.0 and store.get("2026-12") == 0.0


class _FakeSnap:
    def __init__(self, data):
        self.exists = data is not None
        self._data = data

    def to_dict(self):
        return self._data


class _FakeRef:
    def __init__(self, db, path):
        self.db, self.path = db, path

    def set(self, data, merge=False):
        self.db.writes.append((self.path, data, merge))

    def get(self):
        return _FakeSnap(self.db.stored.get(self.path))


class _FakeDb:
    def __init__(self):
        self.writes = []
        self.stored = {}

    def collection(self, name):
        db = self

        class Col:
            def document(self, doc_id):
                return _FakeRef(db, f"{name}/{doc_id}")

        return Col()


def test_firestore_spend_key_and_increment():
    from firebase_admin import firestore

    from backend.firebase_store import FirestoreSpend, _spend_doc_id

    assert _spend_doc_id("2026-11") == "llm_spend_2026-11"
    store = object.__new__(FirestoreSpend)
    store.db = _FakeDb()
    store.add("2026-11", 12.5)
    (path, data, merge), = store.db.writes
    assert path == "ops/llm_spend_2026-11" and merge is True and data["month"] == "2026-11"
    assert isinstance(data["krw"], type(firestore.Increment(1)))  # 덮어쓰기가 아니라 증가 연산
    store.db.stored["ops/llm_spend_2026-11"] = {"krw": 12.5}
    assert store.get("2026-11") == 12.5 and store.get("2026-12") == 0.0


def test_report_records_harness_version_in_doc_key_and_log(client, deps, caplog):
    """저장본 문서·키·로그에 지침 버전 (backend/agent/harness)."""
    import logging

    from backend.agent.prompt import HARNESS_VERSION
    from backend.agent.report_cache import cache_key

    consent(client)
    caplog.set_level(logging.INFO, logger="gwittim.agent.service")
    analyze(client)
    (doc,) = deps.reports.docs["alice"].values()
    assert doc["harness_version"] == HARNESS_VERSION
    assert doc["key"] != cache_key(NOTICE, {}) and len(doc["key"]) == 64
    assert f"harness={HARNESS_VERSION}" in caplog.text


# ---------- 시연용 크레딧 채우기 ----------

def test_demo_refill_is_404_unless_enabled(client, monkeypatch):
    monkeypatch.delenv("GWITTIM_DEMO_CREDITS", raising=False)
    assert client.post("/v1/credits/demo-refill", headers=ALICE).status_code == 404
    monkeypatch.setenv("GWITTIM_DEMO_CREDITS", "0")
    assert client.post("/v1/credits/demo-refill", headers=ALICE).status_code == 404


def test_demo_refill_needs_login(client, monkeypatch):
    monkeypatch.setenv("GWITTIM_DEMO_CREDITS", "1")
    assert client.post("/v1/credits/demo-refill").status_code == 401


def test_demo_refill_fills_to_max_and_logs_demo_entry(client, monkeypatch):
    monkeypatch.setenv("GWITTIM_DEMO_CREDITS", "1")
    consent(client)
    analyze(client)
    analyze(client, "r2", chips={"experience": ["java"]})
    assert client.get("/v1/credits", headers=ALICE).json()["balance"] == 3
    out = client.post("/v1/credits/demo-refill", headers=ALICE).json()
    assert schema_errors("credits", out) == []
    assert out["balance"] == 5
    assert out["entries"][0] == {"kind": "demo", "amount": 2, "at": "2026-10-17T03:05:00Z", "ref": None}
    # 이미 가득이면 내역을 더하지 않는다
    again = client.post("/v1/credits/demo-refill", headers=ALICE).json()
    assert again["balance"] == 5
    assert [e["kind"] for e in again["entries"]].count("demo") == 1
    # 다른 사용자 잔액은 그대로
    assert client.get("/v1/credits", headers=BOB).json()["entries"] == [
        {"kind": "signup", "amount": 5, "at": "2026-10-17T03:05:00Z", "ref": None}
    ]


# ---------- 게스트(익명 계정, D-054) ----------

def test_guest_starts_with_three_and_gets_no_daily_refill(client, clock):
    out = client.get("/v1/credits", headers=GUEST).json()
    assert schema_errors("credits", out) == []
    assert out == {
        "balance": 3,
        "next_refill_at": None,
        "entries": [{"kind": "signup", "amount": 3, "at": "2026-10-17T03:05:00Z", "ref": None}],
    }
    clock.moment += timedelta(days=3)
    later = client.get("/v1/credits", headers=GUEST).json()
    assert later["balance"] == 3
    assert later["next_refill_at"] is None
    assert [e["kind"] for e in later["entries"]] == ["signup"]


def test_google_user_unchanged_next_to_guest(client, clock):
    consent(client)
    analyze(client)
    client.get("/v1/credits", headers=GUEST)
    assert client.get("/v1/credits", headers=ALICE).json()["next_refill_at"] == "2026-10-17T15:00:00Z"
    clock.moment += timedelta(days=1)
    assert balance(client) == 5  # 매일 1개


def test_guest_analysis_charges_one_without_refill(client, clock, provider):
    consent(client, GUEST)
    assert analyze(client, headers=GUEST).status_code == 200
    out = client.get("/v1/credits", headers=GUEST).json()
    assert out["balance"] == 2
    assert out["next_refill_at"] is None  # 최대 보유가 아니어도 게스트는 충전 없음
    assert [e["kind"] for e in out["entries"]] == ["detail_analysis", "signup"]
    clock.moment += timedelta(days=1)
    assert balance(client, GUEST) == 2
    assert analyze(client, "r2", chips={"experience": ["java"]}, headers=GUEST).status_code == 200
    assert analyze(client, "r3", chips={"experience": ["c"]}, headers=GUEST).status_code == 200
    assert_error(analyze(client, "r4", chips={"experience": ["go"]}, headers=GUEST), 402, "insufficient_credits")
    assert provider.calls == 3


def test_guest_analysis_failure_refunds(client, deps):
    consent(client, GUEST)
    deps.llm = FailingProvider()
    assert_error(analyze(client, headers=GUEST), 503, "unavailable")
    out = client.get("/v1/credits", headers=GUEST).json()
    assert out["balance"] == 3
    assert [e["kind"] for e in out["entries"]] == ["signup"]


def test_guest_profile_delete_removes_everything(client, deps):
    consent(client, GUEST)
    analyze(client, headers=GUEST)
    assert client.put(f"/v1/saved/{NOTICE}", headers=GUEST).status_code in (200, 201)
    assert deps.saved.list("guest")
    assert client.delete("/v1/profile", headers=GUEST).status_code == 204
    assert "guest" not in deps.reports.docs
    assert "guest" not in deps.credits.states
    assert deps.profiles.get("guest") is None
    assert deps.saved.list("guest") == []
    assert_error(client.get("/v1/profile", headers=GUEST), 404, "not_found")


def test_guest_demo_refill_fills_to_max(client, monkeypatch):
    monkeypatch.setenv("GWITTIM_DEMO_CREDITS", "1")
    out = client.post("/v1/credits/demo-refill", headers=GUEST).json()
    assert out["balance"] == 5
    assert out["next_refill_at"] is None
    assert out["entries"][0] == {"kind": "demo", "amount": 2, "at": "2026-10-17T03:05:00Z", "ref": None}


def test_firebase_verifier_reads_anonymous_provider(monkeypatch):
    from backend import firebase_store
    from backend.api.deps import Caller

    claims = {
        "anon": {"uid": "u1", "firebase": {"sign_in_provider": "anonymous"}},
        "google": {"uid": "u2", "firebase": {"sign_in_provider": "google.com"}},
        "bare": {"uid": "u3"},
    }

    def fake_verify(token, app=None):
        if token not in claims:
            raise ValueError("bad token")
        return claims[token]

    monkeypatch.setattr(firebase_store.auth, "verify_id_token", fake_verify)
    v = firebase_store.FirebaseTokenVerifier(app=None)
    assert v.verify_caller("anon") == Caller("u1", guest=True)
    assert v.verify_caller("google") == Caller("u2", guest=False)
    assert v.verify_caller("bare") == Caller("u3", guest=False)
    assert v.verify_caller("nope") is None
