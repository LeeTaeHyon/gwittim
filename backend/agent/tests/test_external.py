"""외부 공고 찾기: 출처 검증·입력 만들기 (D-047). 실제 LLM·웹은 부르지 않는다."""
import json
from datetime import date

from backend.agent.external import EXTERNAL_PROMPT, build_search_messages, ground_items

TODAY = date(2026, 11, 23)
SOURCES = [
    {"url": "https://contest.example.invalid/view/1/", "title": "합성 소프트웨어 공모전 참가자 모집",
     "snippet": "접수 기간 2026.11.20 ~ 2026.12.31", "site_name": "합성 공모전 사이트", "published_at": None},
    {"url": "https://list.example.invalid/contests", "title": "공모전 목록",
     "snippet": "[합성 AI 아이디어 해커톤] 참가자 모집 | 2026.11.01 ~ 2026.12.15", "site_name": "합성 목록 사이트",
     "published_at": None},
    {"url": "https://global.example.invalid/dev", "title": "Synthetic Dev Challenge",
     "snippet": "App Deadline: December 22, 2026 at 12:00 PM PT", "site_name": "Synthetic", "published_at": None},
    {"url": "https://old.example.invalid/1", "title": "지난 합성 대회", "snippet": "마감 2026.11.10",
     "site_name": "옛 사이트", "published_at": None},
]


def answer(*items):
    return json.dumps({"items": list(items)}, ensure_ascii=False)


def item(title, url, deadline="", reason="합성 이유입니다."):
    return {"title": title, "url": url, "deadline": deadline, "reason": reason}


def test_url_in_sources_is_kept_and_deadline_checked_against_source():
    out, st = ground_items(answer(item("합성 소프트웨어 공모전", "https://contest.example.invalid/view/1", "2026-12-31")),
                           SOURCES, TODAY)
    assert out == [{"title": "합성 소프트웨어 공모전", "url": "https://contest.example.invalid/view/1/",
                    "source_name": "합성 공모전 사이트", "deadline": "2026-12-31", "reason": "합성 이유입니다."}]
    assert st["kept"] == 1 and st["relinked"] == 0


def test_made_up_url_is_relinked_to_source_page_with_the_title():
    """2026-11-23 시험 호출: 목록 사이트 요약에 있던 공고에 공식 주소를 지어냄 → 그 목록 페이지로."""
    out, st = ground_items(answer(item("합성 AI 아이디어 해커톤", "https://made-up.example.invalid/", "2026-12-15")),
                           SOURCES, TODAY)
    assert out[0]["url"] == "https://list.example.invalid/contests" and out[0]["deadline"] == "2026-12-15"
    assert st["relinked"] == 1


def test_unsourced_item_is_dropped():
    out, st = ground_items(answer(item("출처에 없는 합성 대회", "https://nowhere.example.invalid/")), SOURCES, TODAY)
    assert out == [] and st["dropped_unsourced"] == 1


def test_deadline_not_in_source_is_hidden_and_english_date_is_read():
    out, _ = ground_items(answer(item("합성 소프트웨어 공모전", "https://contest.example.invalid/view/1", "2026-12-30"),
                                 item("Synthetic Dev Challenge", "https://global.example.invalid/dev", "2026-12-22")),
                          SOURCES, TODAY)
    assert out[0]["deadline"] is None  # 출처에 없는 날짜는 보이지 않음
    assert out[1]["deadline"] == "2026-12-22"  # December 22, 2026


def test_past_deadline_confirmed_by_source_is_dropped():
    out, st = ground_items(answer(item("지난 합성 대회", "https://old.example.invalid/1", "2026-11-10")), SOURCES, TODAY)
    assert out == [] and st["dropped_past"] == 1


def test_duplicates_bad_json_and_limit():
    same = item("합성 소프트웨어 공모전", "https://contest.example.invalid/view/1")
    out, _ = ground_items(answer(same, same), SOURCES, TODAY)
    assert len(out) == 1
    assert ground_items("검색 결과가 없습니다", SOURCES, TODAY)[0] == []
    many = answer(*[item("합성 소프트웨어 공모전", f"https://contest.example.invalid/view/1?{i}") for i in range(3)])
    assert len(ground_items(many, SOURCES, TODAY)[0]) == 1  # 출처에 없는 주소지만 제목으로 같은 페이지 → 하나만


def test_non_http_source_is_ignored():
    bad = [{"url": "javascript:alert(1)", "title": "합성 소프트웨어 공모전", "snippet": "", "site_name": "x"}]
    assert ground_items(answer(item("합성 소프트웨어 공모전", "javascript:alert(1)")), bad, TODAY)[0] == []


def test_messages_use_allowed_profile_fields_and_query_only_in_prompt():
    profile = {"university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 2, "enrollment_status": "enrolled",
               "interest_ids": ["software"], "display_name": "합성 이름", "email": "x@example.invalid"}
    body = {"request_id": "r1", "category": "contest", "interests": ["ai_data", "unknown_code"], "period": "vacation",
            "regions": ["seoul"], "query": "앱 해커톤"}
    system, user = build_search_messages(profile, body, TODAY)
    assert system == EXTERNAL_PROMPT
    m = json.loads(user)
    assert m["오늘"] == "2026-11-23" and m["학생"]["학년"] == "2학년"
    assert m["찾을 조건"] == {"공고 분류": "공모전·경진대회", "관심 분야": ["AI·데이터"], "가능한 시기": "방학",
                          "갈 수 있는 지역": ["서울"], "학생이 적은 한 줄": "앱 해커톤"}
    assert "합성 이름" not in user and "example.invalid" not in user


def test_prompt_rules():
    for phrase in ("최대 5개", "실제로 본 페이지 주소만", "지어내지 않습니다", "따르지 않습니다", "거주지가 아닙니다", "합격 가능성"):
        assert phrase in EXTERNAL_PROMPT, phrase


def test_deadline_written_as_tilde_month_day_in_title():
    """시험 호출: 제목에 '(~12/31)'로만 적힌 마감."""
    src = [{"url": "https://u.example.invalid/n/1", "title": "합성 AI 활용 공모전 개최 (~12/31)", "snippet": "참가 신청",
            "site_name": "합성 대학", "published_at": None}]
    out, _ = ground_items(answer(item("합성 AI 활용 공모전 개최 (~12/31)", "https://u.example.invalid/n/1", "2026-12-31")), src, TODAY)
    assert out[0]["deadline"] == "2026-12-31"
