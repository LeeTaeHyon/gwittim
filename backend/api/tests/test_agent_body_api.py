"""AI 상세 분석의 공고 본문 입력: 서버 흐름과 노출 범위 (docs/agent-detail-body-spec.md §4.2, §4.6)."""
import json
import logging

from backend.api.deps import InMemoryBodies
from backend.api.tests.test_agent_api import (  # noqa: F401  (픽스처와 도우미를 그대로 쓴다)
    ALICE, NOTICE, analyze, balance, client, clock, consent, deps, provider,
)

BODY = "일시: 12월 3일 14시 / 장소: 본관 301호 / 제출물: 신청서 1부 (비밀표식본문)"


def test_analysis_sends_stored_body_and_reads_it_once(client, deps, provider):
    class CountingBodies(InMemoryBodies):
        reads = 0

        def get(self, notice_id):
            CountingBodies.reads += 1
            return super().get(notice_id)

    deps.bodies = CountingBodies({NOTICE: BODY})
    consent(client)
    assert analyze(client).status_code == 200
    assert json.loads(provider.prompts[0][1])["공고"]["본문"] == BODY
    assert CountingBodies.reads == 1
    assert analyze(client, "r2").json()["from_cache"] is True  # 저장본 재사용은 본문을 읽지 않는다
    assert CountingBodies.reads == 1


def test_analysis_without_stored_body_works_like_before(client, provider):
    consent(client)
    assert analyze(client).status_code == 200
    assert "본문" not in json.loads(provider.prompts[0][1])["공고"]
    assert balance(client) == 4


def test_body_read_failure_does_not_fail_request(client, deps, provider):
    class Broken:
        def get(self, notice_id):
            raise RuntimeError("firestore down")

    deps.bodies = Broken()
    consent(client)
    assert analyze(client).status_code == 200
    assert "본문" not in json.loads(provider.prompts[0][1])["공고"]


def test_body_is_not_in_other_api_responses_or_logs(client, deps, caplog):
    deps.bodies = InMemoryBodies({NOTICE: BODY})
    consent(client)
    with caplog.at_level(logging.DEBUG):
        resp = analyze(client)
    assert "비밀표식본문" not in resp.text
    assert "비밀표식본문" not in caplog.text
    assert "body=present" in caplog.text
    for url in ("/v1/recommendations?limit=50", f"/v1/notices/{NOTICE}", "/v1/saved", f"/v1/analysis/{NOTICE}", "/v1/credits"):
        got = client.get(url, headers=ALICE)
        assert got.status_code == 200, url
        assert "비밀표식본문" not in got.text, url
        assert "body_text" not in got.text, url
