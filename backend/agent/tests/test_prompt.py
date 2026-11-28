import json
import re
from datetime import date

from backend.agent.prompt import SYSTEM_PROMPT, build_messages, scrub_codes

NOTICE = {
    "title": "[일반채용] 합성 AI 인턴십",
    "category": "internship",
    "summary": "합성 요약입니다.",
    "application_deadline": None,
    "activity_period": {
        "start": {"date": "2027-03-02", "time": None, "timezone": None, "precision": "date", "evidence": "3월부터"},
        "end": None, "evidence": "3월부터 5개월",
    },
    "eligibility": {
        "conditions": [{"field": "enrollment_status", "operator": "eq", "value": "graduated",
                        "evidence": "졸업 예정자 또는 기졸업자", "validation_status": "validated"}],
        "unresolved_conditions": [{"evidence": "AI 결과물 경험", "note": "우대 사항"}, {"evidence": "병역필", "note": None}],
        "extraction_complete": True,
        "explicitly_unrestricted": False,
    },
}
PAYLOAD = {
    "university_id": "mjc", "major_id": "mjc.computer_engineering", "grade": 2, "enrollment_status": "enrolled",
    "interest_ids": ["ai_data"], "target_role_ids": ["software_developer"],
    "experience": ["python", "team_project"], "period": "vacation", "regions": ["seoul"],
}
VERDICT = ("not_met", [{"field": "enrollment_status", "status": "not_met",
                        "evidence": "졸업 예정자 또는 기졸업자", "unknown_reason": None}])
CODE_RE = re.compile(r"\b(not_met|needs_check|met|null|true|false|enrollment_status|university_id|major_id|"
                     r"graduated|enrolled|on_leave|team_project|software_developer|ai_data|vacation|seoul|python)\b")


def material():
    _, user = build_messages(NOTICE, PAYLOAD, VERDICT, date(2026, 11, 22))
    return user, json.loads(user)


def test_material_has_no_internal_codes():
    user, _ = material()
    assert not CODE_RE.findall(user)
    assert not re.search(r'"[a-z_]+":', user)  # 칸 이름도 한국어


def test_material_korean_values():
    _, m = material()
    s = m["학생"]
    assert s["학적 상태"] == "재학" and s["학년"] == "2학년" and s["학과"] == "컴퓨터공학과"
    assert s["해 본 것"] == ["파이썬", "팀 프로젝트"] and s["가능한 시기"] == "방학" and s["갈 수 있는 지역"] == ["서울"]
    n = m["공고"]
    assert n["마감"] == "미상"
    assert n["활동 기간"] == "2027-03-02 ~ 미상"
    v = n["지원 자격 판정"]
    assert v["결과"] == "미충족"
    assert v["조건별 결과"] == [{"항목": "학적 상태", "결과": "미충족", "근거": "졸업 예정자 또는 기졸업자",
                             "공고 조건": "졸업·졸업 예정"}]
    assert v["원문에서 확인할 조건"][1] == {"원문": "병역필", "구분": "자격 조건"}
    assert v["참고"] == []  # 조건을 다 찾았고 '누구나' 문구도 없음


def test_notes_are_sentences_not_yes_no():
    el = {**NOTICE["eligibility"], "extraction_complete": False, "explicitly_unrestricted": True}
    _, user = build_messages({**NOTICE, "eligibility": el}, PAYLOAD, VERDICT, date(2026, 11, 22))
    v = json.loads(user)["공고"]["지원 자격 판정"]
    assert v["참고"] == ["공고의 지원 조건을 모두 찾지 못했을 수 있어 원문 확인이 필요함", "공고에 누구나 지원할 수 있다고 적혀 있음"]
    assert "아니요" not in user and '"예"' not in user


def test_missing_profile_fields_are_left_out():
    _, user = build_messages(NOTICE, {}, ("needs_check", []), date(2026, 11, 22))
    assert json.loads(user)["학생"] == {}


def test_activity_period_left_out_when_not_extracted():
    _, user = build_messages({**NOTICE, "activity_period": None}, PAYLOAD, VERDICT, date(2026, 11, 22))
    assert "활동 기간" not in json.loads(user)["공고"]


def test_minute_deadline_keeps_time_without_timezone():
    notice = {**NOTICE, "application_deadline": {"date": "2026-11-30", "time": "18:00", "timezone": None,
                                                 "precision": "minute", "evidence": "18시"}}
    _, user = build_messages(notice, PAYLOAD, VERDICT, date(2026, 11, 22))
    assert json.loads(user)["공고"]["마감"] == "2026-11-30 18:00"


def test_system_prompt_rules():
    assert "영어 코드" in SYSTEM_PROMPT and "가능한 시기" in SYSTEM_PROMPT and "json" in SYSTEM_PROMPT
    assert "칸 이름" in SYSTEM_PROMPT and "연결 근거가 드러나게" in SYSTEM_PROMPT
    assert "null" not in SYSTEM_PROMPT.split("영어 코드")[0]  # 규칙 앞에서 코드를 쓰지 않는다


def test_scrub_replaces_leaked_codes():
    report = {
        "fit": "파이썬(team_project) 경험이 연결됨.",
        "eligibility": "판정은 not_met(미충족)입니다. enrollment_status 조건이 not_met입니다.",
        "todo": "마감은 입력상 null로 마감 미상입니다. `needs_check` 항목 확인.",
        "skills": "공고 원문 확인 필요.",
    }
    out, n = scrub_codes(report)
    assert out["eligibility"] == "판정은 미충족입니다. 학적 상태 조건이 미충족입니다."
    assert out["todo"] == "마감은 입력상 미상로 마감 미상입니다. 확인 필요 항목 확인."
    assert out["fit"] == "파이썬 경험이 연결됨."
    assert out["skills"] == report["skills"]
    assert n == 6


def test_scrub_leaves_urls_and_ordinary_english():
    text = "https://www.mjc.ac.kr/x?menu=met 에서 Python, AI, any 경험 확인. met-life 아님. Metro 근무."
    out, n = scrub_codes({"fit": text})
    assert out["fit"] == text and n == 0


# ---------- 읽기 쉬운 줄 나누기 ----------

from backend.agent.prompt import split_long_lines  # noqa: E402


def test_prompt_asks_short_lines_and_labels():
    assert "줄바꿈(" + chr(92) + "n)" in SYSTEM_PROMPT and "맞음:" in SYSTEM_PROMPT and "미충족:" in SYSTEM_PROMPT
    assert "요구하거나 우대한다고 밝힌 역량만" in SYSTEM_PROMPT and "'(우대)'를 붙입니다" in SYSTEM_PROMPT


def test_split_long_paragraph_at_sentence_ends():
    long = ("공고의 구매 업무는 식자재 계약관리와 구매 운영입니다. 학생이 해 본 데이터 분석은 관련이 적지 않습니다. "
            "근무지가 서울인지는 공고 자료로 확인되지 않아 원문 확인이 필요합니다.")
    out, n = split_long_lines({"fit": long, "skills": "식자재 계약관리\nERP 시스템 (우대)"})
    assert out["fit"].split("\n") == [
        "공고의 구매 업무는 식자재 계약관리와 구매 운영입니다.",
        "학생이 해 본 데이터 분석은 관련이 적지 않습니다.",
        "근무지가 서울인지는 공고 자료로 확인되지 않아 원문 확인이 필요합니다.",
    ]
    assert n == 2
    assert out["skills"] == "식자재 계약관리\nERP 시스템 (우대)"  # 짧은 줄은 그대로


def test_split_keeps_short_lines_and_numbers():
    text = "맞음: 관심 분야와 겹침\n확인 필요: 마감 2026. 11. 30. 이후 일정은 원문 확인"
    out, n = split_long_lines({"fit": text})
    assert out["fit"] == text and n == 0


def test_prompt_first_card_rules():
    """첫 칸(나와 이 공고)·지원 자격·할 일·역량 규칙 (2026-11-23 리포트 개선)."""
    s = SYSTEM_PROMPT
    assert "나와 이 공고" in s and "지원 결정을 가장 크게 바꾸는 사실부터" in s and "최대 2개만" in s
    assert "첫 줄은 마감이 지났다는 사실" in s and "요약·제목에만 있는 내용은 근거가 아닙니다" in s
    assert "어디서 어떻게 쌓았는지" in s and "'방학에만 가능'처럼 넓히거나" in s  # 선택값·경위 추정 금지
    assert "강의 주제, 배울 내용, 모집 대상" in s  # 역량이 아닌 것
    assert "이번 모집은 지원 전에 할 일이 없습니다" in s  # 미충족·마감 지남이고 판단을 바꿀 확인 사항이 없을 때
    assert "거주지가 아닙니다" in s and "단정하지 않고" in s  # 활동 지역은 거주지가 아님
    assert "숙련도나 맡은 역할을 추정하지 않고" in s  # 경험 칩만으로 숙련도 추정 금지
    assert "판정을 가른 조건" in s and "학생 정보가 비어서인지" in s and "공고 조건이 불명확해서인지" in s
    assert "필수 자격이 아니라" in s  # 우대 사항 구분
    assert "지원서 작성을 권하지 않습니다" in s  # 미충족이면
    assert "입력 자료에 없는 일정이나 경로를 만들어 쓰지 않습니다" in s  # '다음 학기·학과 공지' 같은 근거 없는 안내 금지
    assert '"fit"에서 같은 조건을 다시 말하지 않습니다' in s  # 판정 조건은 eligibility에서만
    assert "최대 4줄" in s and "제공된 공고 정보에서 요구 역량을 확인하기 어렵습니다" in s
    assert "번호, 글머리 기호" in s  # 앱이 붙임
    assert "불충족" not in s  # ui-style: 충족 / 미충족 / 확인 필요




# ---------- 근거 맞추기 (역량·할 일) ----------

from backend.agent.prompt import SKILLS_UNKNOWN, TODO_NONE, deadline_passed, ground_report  # noqa: E402

_TODAY = date(2026, 11, 23)


def _notice(unresolved=(), deadline=None):
    return {
        "eligibility": {"unresolved_conditions": [{"evidence": e, "note": n} for e, n in unresolved]},
        "application_deadline": {"date": deadline} if deadline else None,
    }


def _report(skills="", todo="확인합니다."):
    return {"fit": "맞음: 겹침", "eligibility": "확인 필요: 조건", "todo": todo, "skills": skills}


def test_skills_kept_only_with_source_and_preferred_from_source():
    notice = _notice([("AI를 활용해 결과물을 직접 만들어 본 경험이 있는 분", "우대 사항"),
                      ("토익 750점 이상", None)])
    out, ch = ground_report(_report("AI를 활용한 결과물 제작\n토익 750점 이상 (우대)\nSW 개발 역량"), notice, "needs_check", _TODAY)
    # 우대는 원문 구분으로: 앞 줄은 붙이고, 토익은 자격 조건이라 뗀다. 원문에 없는 모집 부문은 뺀다
    assert out["skills"].split("\n") == ["AI를 활용한 결과물 제작 (우대)", "토익 750점 이상"]
    assert ch == {"skills_dropped": 1}


def test_skills_without_source_become_unknown_sentence():
    notice = _notice([("코딩 경험이 없는 비전공자", "LLM 추출")])
    out, ch = ground_report(_report("AI 활용 학습도구 개발 기초\n바이브코딩 실습"), notice, "needs_check", _TODAY)
    assert out["skills"] == SKILLS_UNKNOWN and ch["skills_dropped"] == 2
    out, _ = ground_report(_report(SKILLS_UNKNOWN), _notice(), "met", _TODAY)
    assert out["skills"] == SKILLS_UNKNOWN


def test_deadline_passed_todo_is_fixed_sentence():
    notice = _notice(deadline="2026-11-18")
    assert deadline_passed(notice, _TODAY) and not deadline_passed(_notice(), _TODAY)
    out, ch = ground_report(_report(SKILLS_UNKNOWN, "다음 모집 공고가 나올 때 지원 여부를 판단합니다."), notice, "needs_check", _TODAY)
    assert out["todo"] == TODO_NONE and ch == {"todo": "deadline_passed"}
    out, _ = ground_report(_report(SKILLS_UNKNOWN, "근무지를 확인합니다."), _notice(deadline="2026-11-23"), "needs_check", _TODAY)
    assert out["todo"] == "근무지를 확인합니다."  # 오늘 마감은 아직 지나지 않음


def test_not_met_todo_drops_application_prep_and_made_up_schedule():
    out, ch = ground_report(
        _report(SKILLS_UNKNOWN, "AI를 활용해 만든 결과물을 정리해 둡니다.\n병역 관련 결격사유 여부를 확인합니다."),
        _notice(), "not_met", _TODAY)
    assert out["todo"] == "병역 관련 결격사유 여부를 확인합니다." and ch == {"todo": "not_met_filtered"}
    out, _ = ground_report(_report(SKILLS_UNKNOWN, "다음 학기 학과 공지를 확인합니다."), _notice(), "not_met", _TODAY)
    assert out["todo"] == TODO_NONE
    # 미충족이 아니면 할 일은 그대로
    out, ch = ground_report(_report(SKILLS_UNKNOWN, "지원서 초안을 씁니다."), _notice(), "met", _TODAY)
    assert out["todo"] == "지원서 초안을 씁니다." and ch == {}


def test_material_marks_deadline_passed():
    notice = {
        "title": "합성 공고", "category": None, "summary": "요약",
        "application_deadline": {"date": "2026-11-18", "time": None, "timezone": None, "precision": "date"},
        "eligibility": {"conditions": [], "unresolved_conditions": [], "extraction_complete": True},
    }
    _, user = build_messages(notice, {}, ("met", []), _TODAY)
    assert "마감 지남" in user


# ---------- 경험·우대 조건 잇기 (fit 인용 줄) ----------

_PAY = {"experience": ["app_dev", "contest"]}
_PREF_NOTICE = _notice([("앱 개발 프로젝트 경험이 있는 분", "우대 사항"), ("토익 750점 이상", None)])


def _fit(*lines):
    r = _report(SKILLS_UNKNOWN)
    r["fit"] = "\n".join(lines)
    return r


def test_fit_link_kept_when_quote_in_preferred_and_chip_named():
    line = "맞음: 우대 조건 '앱 개발 프로젝트 경험'에 앱 개발 경험이 이어집니다."
    out, ch = ground_report(_fit(line, "확인 필요: 일정은 공고에 나와 있지 않습니다."), _PREF_NOTICE, "met", _TODAY, _PAY)
    assert out["fit"].split("\n")[0] == line and "fit_link_dropped" not in ch


def test_fit_link_dropped_without_source_chip_or_preferred_note():
    keep = "확인 필요: 일정은 공고에 나와 있지 않습니다."
    # 인용이 원문에 없음
    out, ch = ground_report(_fit("맞음: 우대 조건 '해외 봉사 경험'에 앱 개발 경험이 이어집니다.", keep), _PREF_NOTICE, "met", _TODAY, _PAY)
    assert out["fit"] == keep and ch["fit_link_dropped"] == 1
    # 학생이 고르지 않은 경험
    out, ch = ground_report(_fit("맞음: 우대 조건 '영상 제작 경험'에 영상 편집 경험이 이어집니다.", keep),
                           _notice([("영상 제작 경험이 있는 분", "우대 사항")]), "met", _TODAY, _PAY)
    assert out["fit"] == keep and ch["fit_link_dropped"] == 1
    # 우대 사항이 아닌 원문(필수 조건)
    out, ch = ground_report(_fit("맞음: 우대 조건 '토익 750점'에 앱 개발 경험이 이어집니다.", keep), _PREF_NOTICE, "met", _TODAY, _PAY)
    assert out["fit"] == keep and ch["fit_link_dropped"] == 1


def test_fit_without_quote_untouched_and_all_dropped_gives_fixed_sentence():
    r = _fit("맞음: 이번 공모전은 앱 시제품을 제출하므로 앱 개발 경험을 활용할 수 있습니다.")
    out, ch = ground_report(r, _PREF_NOTICE, "met", _TODAY, _PAY)
    assert out["fit"] == r["fit"] and ch == {}
    out, ch = ground_report(_fit("맞음: 우대 조건 '없는 구절'에 앱 개발 경험이 이어집니다."), _PREF_NOTICE, "met", _TODAY, _PAY)
    assert out["fit"].startswith("확인 필요:") and ch == {"fit_link_dropped": 1}
    # 학생 정보(payload)를 주지 않으면 이 검사는 하지 않는다(기존 호출과 호환)
    out, _ = ground_report(_fit("맞음: 우대 조건 '없는 구절'에 앱 개발 경험이 이어집니다."), _PREF_NOTICE, "met", _TODAY)
    assert "없는 구절" in out["fit"]


def test_ordinary_quote_without_preferred_word_is_kept():
    """'우대'가 없는 줄의 인용(학생 선택값 등)은 우대 연결 검사 대상이 아니다."""
    line = "맞음: 가능한 시기 '방학'과 활동 기간이 겹칩니다."
    out, ch = ground_report(_fit(line), _PREF_NOTICE, "met", _TODAY, _PAY)
    assert out["fit"] == line and ch == {}


def test_hedged_met_line_relabeled_to_check():
    """'맞음:'인데 단정하지 않는 줄은 '확인 필요:'로 바뀐다(2026-11-28 DeepSeek 확인에서 나온 줄)."""
    hedged = "맞음: 우대 조건 '앱 개발 프로젝트 경험'에 앱 개발 경험이 이어지는지 확인할 수 있습니다."
    keep = "확인 필요: 일정은 공고에 나와 있지 않습니다."
    out, ch = ground_report(_fit(hedged, keep), _PREF_NOTICE, "met", _TODAY, _PAY)
    assert out["fit"].split("\n") == ["확인 필요:" + hedged[len("맞음:"):], keep]
    assert ch == {"fit_hedge_relabeled": 1}
    out, ch = ground_report(_fit("맞음: 실습 도구가 파이썬 기반일 수 있습니다."), _PREF_NOTICE, "met", _TODAY)
    assert out["fit"].startswith("확인 필요:") and ch == {"fit_hedge_relabeled": 1}


def test_il_su_itda_checked_by_word():
    """'경험일 수 있습니다'(추측)는 바꾸고, '줄일 수 있습니다'(동사)는 그대로 둔다."""
    line = "맞음: 파이썬 자동화 경험으로 작업 시간을 줄일 수 있습니다."
    out, ch = ground_report(_fit(line), _PREF_NOTICE, "met", _TODAY)
    assert out["fit"] == line and ch == {}
    out, ch = ground_report(_fit("맞음: 공고가 찾는 것이 파이썬 경험일 수 있습니다."), _PREF_NOTICE, "met", _TODAY)
    assert out["fit"].startswith("확인 필요:") and ch == {"fit_hedge_relabeled": 1}
    # 어절 전체로 대조한다. '홍보일'은 동사 '보일'이 아니다
    out, ch = ground_report(_fit("맞음: 주요 활동은 홍보일 수 있습니다."), _PREF_NOTICE, "met", _TODAY)
    assert out["fit"].startswith("확인 필요:") and ch == {"fit_hedge_relabeled": 1}


def test_hedge_checked_in_conclusion_clause_only():
    """앞 절의 '확인이 필요하지만,'은 결론이 아니다. 마지막 절이 단정이면 '맞음'을 둔다."""
    line = "맞음: 세부 일정은 확인이 필요하지만, 공고의 앱 시제품 제작에 앱 개발 경험을 활용할 수 있습니다."
    out, ch = ground_report(_fit(line), _PREF_NOTICE, "met", _TODAY)
    assert out["fit"] == line and ch == {}


def test_definite_met_line_kept():
    line = "맞음: 이번 공모전은 앱 시제품을 제출하므로 앱 개발 경험을 활용할 수 있습니다."
    out, ch = ground_report(_fit(line), _PREF_NOTICE, "met", _TODAY, _PAY)
    assert out["fit"] == line and ch == {}
