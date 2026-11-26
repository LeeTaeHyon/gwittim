"""카카오톡 공고 수동 전달 API (D-058). 합성 글만 쓴다. LLM·실제 저장소는 쓰지 않는다."""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from backend.api import Deps, FakeTokenVerifier, InMemoryNotices, InMemoryProfiles, InMemorySaved, create_app
from backend.contracts import schema_errors
from backend.shared_notices.service import DAILY_LIMIT, SHARE_CONSENT_VERSION
from backend.sources import source_config

ALICE = {"Authorization": "Bearer token-alice"}
BOB = {"Authorization": "Bearer token-bob"}
GUEST = {"Authorization": "Bearer token-guest"}

TEXT = (
    "[합성 샘플] 취업 역량 강화 특강 안내\n"
    "안녕하세요. 합성 대학 취업지원센터입니다.\n"
    "- 신청 기간: 12월 3일(목)까지\n"
    "- 특강 일시: 12월 10일(목) 14시\n"
    "- 신청 방법: 합성 학교 사이트에서 신청\n"
    "- 대상: 재학생 누구나"
)


class Clock:
    def __init__(self):
        self.moment = datetime(2026, 11, 26, 3, 5, tzinfo=timezone.utc)  # KST 11/26 12:05

    def now(self):
        return self.moment


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def deps(clock):
    return Deps(
        verifier=FakeTokenVerifier({"token-alice": "alice", "token-bob": "bob"}, guest_tokens={"token-guest": "guest"}),
        notices=InMemoryNotices({}),
        profiles=InMemoryProfiles(),
        saved=InMemorySaved(),
        clock=clock,
    )


@pytest.fixture
def client(deps):
    return TestClient(create_app(deps))


def body(text=TEXT, input="paste", **extra):
    return {"text": text, "input": input, "consent_version": SHARE_CONSENT_VERSION, **extra}


def variant(n):
    """같은 글을 다시 넘기면 묶이므로, 여러 건이 필요한 시험은 본문을 달리한다."""
    return TEXT + f"\n- 문의 번호: {n}번 창구"


def post(client, payload, headers=ALICE):
    return client.post("/v1/shared-notices", headers=headers, json=payload)


def error_code(resp):
    assert schema_errors("api_error", resp.json()) == []
    return resp.json()["error"]["code"]


def test_submit_analyzes_and_returns_item(client, deps):
    resp = post(client, body())
    assert resp.status_code == 200
    item = resp.json()
    assert schema_errors("shared_notice_response", item) == []
    notice = item["notice"]
    assert notice["source_id"] == "user_share" and notice["source_url"] is None
    assert notice["published"]["timezone"] is None and notice["published"]["date"] == "2026-11-26"
    assert notice["application_deadline"]["date"] == "2026-12-03"
    assert notice["application_deadline"]["timezone"] is None  # 사용자 입력 출처라 시간대를 확정하지 않는다
    assert notice["title"].startswith("[합성 샘플]")
    assert item["input"] == "paste"
    assert item["eligibility"]["eligibility_status"] == "needs_check"  # 프로필이 없으면 확인 필요
    [stored] = deps.shared.list("alice")
    assert stored["id"] == item["id"] and stored["consent_version"] == SHARE_CONSENT_VERSION
    assert stored["analysis_version"] == notice["analysis_version"] and stored["model_version"]


def test_no_llm_and_no_credits(client, deps):
    post(client, body())
    assert deps.credits.states == {}  # 크레딧 상태를 만들지도 차감하지도 않는다


def test_source_has_no_school_or_timezone():
    cfg = source_config("user_share")
    assert cfg.university_id is None and cfg.timezone is None


def test_eligibility_uses_current_profile(client):
    profile = {
        "university_id": None,
        "major_id": None,
        "grade": None,
        "enrollment_status": "enrolled",
        "interest_ids": [],
        "target_role_ids": [],
    }
    assert client.put("/v1/profile", headers=ALICE, json=profile).status_code == 200
    item = post(client, body()).json()
    assert item["eligibility"]["eligibility_status"] == "met"
    listed = client.get("/v1/shared-notices", headers=ALICE).json()
    assert listed["items"][0]["eligibility"]["eligibility_status"] == "met"


@pytest.mark.parametrize(
    "text",
    [
        "[합성 과목] 합성프로그래밍 801반 학습 안내입니다.\n아직 수강하지 않았습니다. 수강기한 안에 수강해 주십시오.",
        "[합성 센터] 합성 자격시험 결과 안내\n2024000001 학생의 결과: 합격 처리가 완료되었습니다. 확인해 주십시오.",
        "안녕하세요. 합성 센터입니다.\n문의: 합성센터 000-0000\n[합성 센터]",  # 인사·문의·머리말뿐인 빈 템플릿
    ],
)
def test_personal_or_noise_is_not_analyzed_or_stored(client, deps, text):
    resp = post(client, body(text=text))
    assert resp.status_code == 200
    assert resp.json() == {"stored": False, "reason": "personal_notice"}
    assert schema_errors("shared_notice_response", resp.json()) == []
    assert deps.shared.docs == {}


def test_server_masks_again_before_storing(client, deps):
    leaked = TEXT + "\n- 문의: 학번 2024123456, 010-1234-5678\n- 담당교수: 김합성"
    item = post(client, body(text=leaked)).json()
    [stored] = deps.shared.list("alice")
    dumped = repr(stored) + repr(item)
    for secret in ("2024123456", "010-1234-5678", "김합성"):
        assert secret not in dumped
    assert "<학번>" in stored["text"] and "<휴대폰>" in stored["text"] and "<교수>" in stored["text"]


def test_year_less_dates_follow_share_day(client, clock):
    clock.moment = datetime(2026, 12, 20, 3, 0, tzinfo=timezone.utc)  # 연말에 넘긴 '1월' 마감은 다음 해로 읽는다
    text = "[합성 샘플] 합성 장학 신청 안내\n- 신청 기간: 1월 8일(금)까지\n- 대상: 재학생 누구나 신청 가능"
    notice = post(client, body(text=text)).json()["notice"]
    assert notice["application_deadline"]["date"] == "2027-01-08"
    assert notice["published"]["date"] == "2026-12-20"


def test_daily_limit_then_next_day(client, clock):
    for n in range(DAILY_LIMIT):
        assert post(client, body(variant(n))).status_code == 200
    resp = post(client, body(variant(99)))
    assert resp.status_code == 429 and error_code(resp) == "rate_limited"
    assert post(client, body(variant(99)), BOB).status_code == 200  # 사람마다 센다
    clock.moment += timedelta(days=1)
    assert post(client, body(variant(99))).status_code == 200


def test_guest_can_submit(client, deps):
    assert post(client, body(), GUEST).status_code == 200
    assert len(deps.shared.list("guest")) == 1


def test_consent_version_must_match(client, deps):
    resp = post(client, {**body(), "consent_version": "1999-01-01"})
    assert resp.status_code == 403 and error_code(resp) == "consent_required"
    assert deps.shared.docs == {}


@pytest.mark.parametrize(
    "payload",
    [
        {"input": "paste", "consent_version": SHARE_CONSENT_VERSION},  # 글 없음
        body(text="너무 짧은 글"),
        body(text="가" * 5001),
        body(input="clipboard_image"),
        body(input="share_image_ocr"),  # ocr_edited 없음
        body(ocr_edited=True),  # OCR이 아닌데 ocr_edited
        {**body(), "image": "synthetic"},  # 이미지는 받지 않는다
    ],
)
def test_invalid_requests(client, deps, payload):
    resp = post(client, payload)
    assert resp.status_code == 400 and error_code(resp) == "invalid_argument"
    assert deps.shared.docs == {}


def test_ocr_request_records_edit_flag(client, deps):
    assert post(client, body(input="share_image_ocr", ocr_edited=True)).status_code == 200
    [stored] = deps.shared.list("alice")
    assert stored["input"] == "share_image_ocr" and stored["ocr_edited"] is True


def test_requires_login(client):
    assert client.post("/v1/shared-notices", json=body()).status_code == 401
    assert client.get("/v1/shared-notices").status_code == 401
    assert client.delete("/v1/shared-notices/x").status_code == 401


def test_list_is_mine_only_newest_first(client, clock):
    first = post(client, body(variant(1))).json()["id"]
    clock.moment += timedelta(minutes=1)
    second = post(client, body(variant(2))).json()["id"]
    post(client, body(), BOB)
    mine = client.get("/v1/shared-notices", headers=ALICE).json()
    assert schema_errors("shared_notice_list_response", mine) == []
    assert [i["id"] for i in mine["items"]] == [second, first]
    assert len(client.get("/v1/shared-notices", headers=BOB).json()["items"]) == 1


def test_cannot_delete_others_and_delete_is_repeatable(client):
    mine = post(client, body()).json()["id"]
    assert client.delete(f"/v1/shared-notices/{mine}", headers=BOB).status_code == 204
    assert len(client.get("/v1/shared-notices", headers=ALICE).json()["items"]) == 1  # 남의 삭제는 아무 일도 하지 않음
    assert client.delete(f"/v1/shared-notices/{mine}", headers=ALICE).status_code == 204
    assert client.delete(f"/v1/shared-notices/{mine}", headers=ALICE).status_code == 204
    assert client.get("/v1/shared-notices", headers=ALICE).json()["items"] == []


def test_account_deletion_removes_shared_notices(client, deps):
    post(client, body())
    post(client, body(), BOB)
    assert client.delete("/v1/profile", headers=ALICE).status_code == 204
    assert "alice" not in deps.shared.docs and "bob" in deps.shared.docs


def test_not_mixed_into_public_recommendations(client):
    post(client, body())
    assert client.get("/v1/recommendations", headers=BOB).json()["items"] == []
    assert client.get("/v1/recommendations", headers=ALICE).json()["items"] == []


def test_same_text_again_returns_existing_item(client, deps, clock):
    first = post(client, body()).json()
    clock.moment += timedelta(minutes=5)
    spaced = "  " + TEXT.replace("\n", "\n\n").replace(" ", "  ") + "\n"
    again = post(client, body(text=spaced)).json()  # 공백·줄 바꿈만 다름
    assert again["id"] == first["id"] and again["created_at"] == first["created_at"]
    assert schema_errors("shared_notice_response", again) == []
    assert len(deps.shared.list("alice")) == 1
    assert post(client, body(), BOB).json()["id"] != first["id"]  # 다른 사람은 따로 저장


def test_duplicate_does_not_count_toward_daily_limit(client, deps):
    for n in range(DAILY_LIMIT - 1):
        assert post(client, body(variant(n))).status_code == 200
    for _ in range(5):
        assert post(client, body(variant(0))).status_code == 200  # 묶인 요청은 세지 않는다
    assert post(client, body(variant(500))).status_code == 200  # 마지막 한 건은 아직 가능
    assert post(client, body(variant(501))).status_code == 429


def test_account_lines_are_masked_before_store(client, deps):
    text = TEXT + "\n- 입금 계좌: 국민은행 123456-78-901234 (홍길동)\n- 참가비 30,000원"
    resp = post(client, body(text=text))
    stored = deps.shared.list("alice")[0]["text"]
    assert "123456" not in stored and "홍길동" not in stored
    assert "<계좌>" in stored and "30,000원" in stored
    assert "123456" not in str(resp.json())
