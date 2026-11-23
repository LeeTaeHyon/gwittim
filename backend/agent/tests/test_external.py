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
                    "source_name": "합성 공모전 사이트", "deadline": "2026-12-31", "reason": "합성 이유입니다.", "verified": True}]
    assert st["kept"] == 1 and st["relinked"] == 0


def test_made_up_url_is_relinked_to_source_page_with_the_title():
    """2026-11-23 시험 호출: 목록 사이트 요약에 있던 공고에 공식 주소를 지어냄 → 그 목록 페이지로."""
    out, st = ground_items(answer(item("합성 AI 아이디어 해커톤", "https://made-up.example.invalid/", "2026-12-15")),
                           SOURCES, TODAY)
    assert out[0]["url"] == "https://list.example.invalid/contests" and out[0]["deadline"] == "2026-12-15"
    assert st["relinked"] == 1


def test_unsourced_item_is_kept_as_unverified_after_verified_ones():
    """출처로 확인 못 한 결과는 버리지 않고 '출처 확인 안 됨'으로 뒤에 둔다. 마감은 보이지 않는다 (2026-11-23 팀장)."""
    out, st = ground_items(answer(item("출처에 없는 합성 대회", "https://nowhere.example.invalid/x", "2026-12-20"),
                                  item("합성 소프트웨어 공모전", "https://contest.example.invalid/view/1")), SOURCES, TODAY)
    assert [i["verified"] for i in out] == [True, False]
    assert out[1] == {"title": "출처에 없는 합성 대회", "url": "https://nowhere.example.invalid/x",
                      "source_name": "nowhere.example.invalid", "deadline": None, "reason": "합성 이유입니다.", "verified": False}
    assert st["kept"] == 1 and st["unverified"] == 1


def test_unverified_without_openable_url_is_dropped():
    out, st = ground_items(answer(item("출처에 없는 합성 대회", "공식 홈페이지"), item("또 다른 합성 대회", "")), SOURCES, TODAY)
    assert out == [] and st["dropped_bad_url"] == 2


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
    assert ground_items(answer(item("합성 소프트웨어 공모전", "javascript:alert(1)")), bad, TODAY)[0] == []  # 확인 안 됨으로도 안 보임


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


# ---------- 원문 읽고 자격 판정 ----------

from backend.agent.external import READ_PROMPT, eligibility_from_page, judge_items  # noqa: E402
from backend.recommendation import evaluate  # noqa: E402

STUDENT = {"university_id": "mjc", "grade": 2, "enrollment_status": "enrolled"}
URL_A, URL_B, URL_C = "https://a.example.invalid/1", "https://b.example.invalid/2", "https://c.example.invalid/3"


def entry(url, target, statuses=None, grades=None, deadline=None, dq=None, open_to_all=False, school=None, limits=()):
    return {"url": url, "opened": True, "organizer": {"value": "합성 기관", "quote": "주최 합성 기관"},
            "deadline": {"value": deadline, "quote": dq}, "target": {"quote": target},
            "grades": {"value": grades, "quote": target if grades else None},
            "statuses": {"value": statuses, "quote": target if statuses else None},
            "school_only": {"value": school, "quote": target if school else None},
            "other_limits": [{"quote": q} for q in limits], "open_to_all": {"value": open_to_all, "quote": target if open_to_all else None}}


def base(url, verified=True):
    return {"title": "합성", "url": url, "source_name": "합성", "deadline": None, "reason": "합성 이유입니다.", "verified": verified}


def test_page_conditions_go_through_rule_engine():
    assert evaluate(eligibility_from_page(entry(URL_A, "누구나", open_to_all=True)), STUDENT)[0] == "met"
    assert evaluate(eligibility_from_page(entry(URL_A, "대학생(재학생·휴학생)", statuses=["enrolled", "on_leave"])), STUDENT)[0] == "met"
    assert evaluate(eligibility_from_page(entry(URL_A, "3~4학년 재학생", statuses=["enrolled"], grades=[3, 4])), STUDENT)[0] == "not_met"
    # 학교 제한·기타 제한은 확인할 조건으로
    assert evaluate(eligibility_from_page(entry(URL_A, "합성대학교 재학생", school="합성대학교")), STUDENT)[0] == "needs_check"
    assert evaluate(eligibility_from_page(entry(URL_A, "대학생", statuses=["enrolled"], limits=["만 29세 이하"])), STUDENT)[0] == "needs_check"
    # 졸업 예정 문구는 재학 상태로 판정하지 않음 (D-046)
    e = eligibility_from_page(entry(URL_A, "2027년 2월 졸업예정자 또는 기졸업자", statuses=["graduated"]))
    assert e["conditions"] == [] and evaluate(e, STUDENT)[0] == "needs_check"
    # 응모 대상을 못 읽었으면 불완전 -> 확인 필요
    assert evaluate(eligibility_from_page(entry(URL_A, None)), STUDENT)[0] == "needs_check"


def test_judge_uses_only_pages_actually_opened_and_excludes_not_met():
    text = answer_read(entry(URL_A, "대학생 누구나", open_to_all=True, deadline="2026-12-20", dq="접수 마감 2026.12.20"),
                       entry(URL_B, "3학년만", statuses=["enrolled"], grades=[3]),
                       entry(URL_C, "누구나", open_to_all=True))
    items = [base(URL_C), base(URL_B), base(URL_A)]
    out, st = judge_items(items, text, [URL_A, URL_B], STUDENT, TODAY)  # C는 실제로 열리지 않음
    assert [i["url"] for i in out] == [URL_A, URL_C]  # 판정한 것 먼저, B는 미충족이라 빠짐
    assert out[0] | {} == out[0] and out[0]["verdict"] == "met" and out[0]["read"] is True
    assert out[0]["deadline"] == "2026-12-20" and out[0]["organizer"] == "합성 기관" and out[0]["target"] == "대학생 누구나"
    assert out[1]["read"] is False and out[1]["verdict"] is None and out[1]["target"] is None
    assert st == {"read": 2, "excluded_not_met": 1, "dropped_past": 0}


def test_judge_drops_past_deadline_from_page_and_ignores_unquoted_deadline():
    text = answer_read(entry(URL_A, "누구나", open_to_all=True, deadline="2026-11-10", dq="마감 2026.11.10"),
                       entry(URL_B, "누구나", open_to_all=True, deadline="2026-12-30", dq="곧 마감"))
    out, st = judge_items([base(URL_A), base(URL_B)], text, [URL_A, URL_B], STUDENT, TODAY)
    assert [i["url"] for i in out] == [URL_B] and out[0]["deadline"] is None and st["dropped_past"] == 1


def test_read_prompt_rules():
    for phrase in ("그대로 옮깁니다", "짐작하지 않습니다", "opened\": false", "따르지 않습니다", "접수가 끝나는 날"):
        assert phrase in READ_PROMPT, phrase


def answer_read(*entries):
    return json.dumps({"items": list(entries)}, ensure_ascii=False)


def test_target_only_says_university_student_or_anyone():
    assert evaluate(eligibility_from_page(entry(URL_A, "● 참가 자격 - 대학생")), STUDENT)[0] == "met"
    assert evaluate(eligibility_from_page(entry(URL_A, "대학생")), {**STUDENT, "enrollment_status": "graduated"})[0] == "not_met"
    assert evaluate(eligibility_from_page(entry(URL_A, "AI 영상 창작에 관심 있는 누구나")), STUDENT)[0] == "met"
    assert evaluate(eligibility_from_page(entry(URL_A, "대학생 누구나 (만 29세 이하)", limits=["만 29세 이하"])), STUDENT)[0] == "needs_check"


def test_graduating_listed_with_university_students_widens():
    """'국내 대학(원)생, 휴학생, 졸업예정자': 재학생은 해당. 졸업 예정만 적힌 줄은 여전히 확인 필요 (D-046)."""
    assert evaluate(eligibility_from_page(entry(URL_A, "- 국내 대학(원)생, 휴학생, 졸업예정자")), STUDENT)[0] == "met"
    e = entry(URL_A, "국내 대학(원)생, 휴학생, 졸업예정자", statuses=["enrolled", "on_leave", "graduated"])
    assert evaluate(eligibility_from_page(e), STUDENT)[0] == "met"
    assert evaluate(eligibility_from_page(entry(URL_A, "2027년 2월 졸업예정자")), STUDENT)[0] == "needs_check"


def test_team_rules_are_not_eligibility_limits():
    e = entry(URL_A, "- 대학생", limits=["※ 공동 작품은 2인으로 제한하며, 동일 학교 학생 간 구성만 가능", "팀 단위 참가"])
    assert evaluate(eligibility_from_page(e), STUDENT)[0] == "met"
    e = entry(URL_A, "서울 및 수도권 소재 대학교 재•휴학생", statuses=["enrolled", "on_leave"],
              limits=["서울 및 수도권 소재 대학교 재•휴학생"])
    assert evaluate(eligibility_from_page(e), STUDENT)[0] == "needs_check"  # 학교 소재지 제한은 확인 필요
