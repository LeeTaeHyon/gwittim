"""외부 공고 찾기 API (D-047). 제공자는 가짜만 쓰고 실제 LLM·웹은 부르지 않는다."""
import json
import logging
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend.agent import llm
from backend.api import Deps, FakeTokenVerifier, InMemoryNotices, InMemoryProfiles, InMemorySaved, create_app
from backend.contracts import schema_errors

ROOT = Path(__file__).resolve().parents[3]
ALICE = {"Authorization": "Bearer token-alice"}
CONSENT = {"version": "2026-11-21", "agreed_at": "2020-01-01T00:00:00Z"}


class Clock:
    moment = datetime(2026, 11, 23, 3, 0, tzinfo=timezone.utc)  # KST 11/23 12:00

    def now(self):
        return self.moment


class SearchProvider:
    """FakeProvider의 합성 검색 결과를 돌려주고, 받은 프롬프트를 기록한다."""

    name = "search"

    def __init__(self, text=None, sources=None, fail=False):
        self.calls, self.prompts = 0, []
        self.text, self.sources, self.fail = text, sources, fail

    def web_search(self, system, user):
        self.calls += 1
        self.prompts.append(user)
        if self.fail:
            raise llm.ProviderCallError("호출 실패")
        r = llm.FakeProvider(env={}).web_search(system, user)
        return llm.WebSearchResult(self.text if self.text is not None else r.text,
                                   self.sources if self.sources is not None else r.sources,
                                   llm.Usage("search", 1.0, 10000, 500, 0.15, 0.60))


class ReadingProvider(SearchProvider):
    """검색 + 원문 읽기(FakeProvider 합성: 첫 출처만 열림, 대학생 재학·휴학)."""

    def read_pages(self, system, user):
        r = llm.FakeProvider(env={}).read_pages(system, user)
        return llm.WebSearchResult(r.text, [], llm.Usage("search", 1.0, 2000, 300, 0.15, 0.60), r.read_urls)


def make_client(provider):
    deps = Deps(
        verifier=FakeTokenVerifier({"token-alice": "alice"}),
        notices=InMemoryNotices({}), profiles=InMemoryProfiles(), saved=InMemorySaved(),
        clock=Clock(), llm=provider,
    )
    return TestClient(create_app(deps), raise_server_exceptions=False), deps


def consent(client):
    body = json.loads((ROOT / "fixtures/valid/user_profile/complete.json").read_text(encoding="utf-8"))
    del body["updated_at"]
    body["agent_consent"] = CONSENT
    assert client.put("/v1/profile", headers=ALICE, json=body).status_code == 200


def search(client, **body):
    return client.post("/v1/external-search", headers=ALICE, json={"request_id": "r1", **body})


def balance(client):
    return client.get("/v1/credits", headers=ALICE).json()["balance"]


def code(resp):
    return resp.json()["error"]["code"]


@pytest.fixture
def provider():
    return SearchProvider()


def test_found_results_are_grounded_and_cost_two_credits(provider):
    client, deps = make_client(provider)
    consent(client)
    resp = search(client, category="contest", period="vacation", regions=["seoul"], query="앱 해커톤")
    assert resp.status_code == 200
    data = resp.json()
    assert schema_errors("external_search_response", data) == []
    # 합성 답 3개: 출처 주소 1, 목록 페이지로 다시 연결 1, 출처 없음 1('출처 확인 안 됨'으로 맨 뒤)
    assert [i["url"] for i in data["items"]] == ["https://contest.example.invalid/view/1", "https://list.example.invalid/contests",
                                                 "https://nowhere.example.invalid/"]
    assert [i["verified"] for i in data["items"]] == [True, True, False]
    assert data["items"][0]["deadline"] == "2026-12-31" and data["charged"] is True
    assert balance(client) == 3
    assert deps.spend.get("2026-11") > 0


def test_nothing_found_is_refunded():
    client, _ = make_client(SearchProvider(text='{"items": []}'))
    consent(client)
    data = search(client).json()
    assert data["items"] == [] and data["charged"] is False
    assert balance(client) == 5


def test_failure_is_refunded_and_unavailable():
    client, _ = make_client(SearchProvider(fail=True))
    consent(client)
    resp = search(client)
    assert resp.status_code == 503 and code(resp) == "unavailable"
    assert balance(client) == 5


def test_requires_consent_and_valid_input(provider):
    client, _ = make_client(provider)
    assert code(search(client)) == "consent_required"
    consent(client)
    assert code(search(client, query="가" * 51)) == "invalid_argument"  # 자르지 않고 거절
    assert code(search(client, regions=["any", "seoul"])) == "invalid_argument"
    assert code(client.post("/v1/external-search", headers=ALICE, json={"query": "x"})) == "invalid_argument"
    assert provider.calls == 0 and balance(client) == 5


def test_same_request_id_is_not_charged_twice(provider):
    client, _ = make_client(provider)
    consent(client)
    assert search(client).status_code == 200
    assert code(search(client)) == "not_found"  # 결과를 저장하지 않으므로 다시 줄 것이 없음, 차감도 없음
    assert balance(client) == 3 and provider.calls == 1


def test_insufficient_credits(provider):
    client, _ = make_client(provider)
    consent(client)
    for i in range(2):
        assert client.post("/v1/external-search", headers=ALICE, json={"request_id": f"r{i}"}).status_code == 200
    assert balance(client) == 1
    assert code(client.post("/v1/external-search", headers=ALICE, json={"request_id": "r9"})) == "insufficient_credits"


def test_query_is_sent_to_model_but_not_logged(provider, caplog):
    client, _ = make_client(provider)
    consent(client)
    with caplog.at_level(logging.INFO):
        search(client, query="합성비밀문장")
    assert "합성비밀문장" in provider.prompts[0]
    assert "합성비밀문장" not in caplog.text
    assert "external search done" in caplog.text


def test_provider_without_web_search_is_unavailable():
    class OnlyReport:
        name = "only"

        def generate(self, system, user, notice_id=None):
            raise AssertionError("부르면 안 됨")

    client, _ = make_client(OnlyReport())
    consent(client)
    assert code(search(client)) == "unavailable"
    assert balance(client) == 5


def test_reading_adds_verdict_target_and_organizer():
    client, _ = make_client(ReadingProvider())
    consent(client)
    data = search(client).json()
    assert schema_errors("external_search_response", data) == []
    first = data["items"][0]
    assert first["read"] is True and first["verdict"] == "met"  # 프로필(재학)과 '재학생·휴학생' 조건
    assert first["organizer"] == "합성 주최 기관" and "대학생" in first["target"]
    assert all(i["read"] is False and i["verdict"] is None for i in data["items"][1:])
    assert data["excluded_not_met"] == 0


def test_read_failure_still_returns_search_results():
    class BrokenRead(SearchProvider):
        def read_pages(self, system, user):
            raise llm.ProviderCallError("읽기 실패")

    client, _ = make_client(BrokenRead())
    consent(client)
    data = search(client).json()
    assert data["charged"] is True and len(data["items"]) == 3
    assert all(i["verdict"] is None for i in data["items"])
